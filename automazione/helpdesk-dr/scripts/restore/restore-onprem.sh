#!/usr/bin/env bash
# Ripristina lo storage del sito DR nel database applicativo Helios.
#
# L'applicazione del sito DR e' SEMPRE E SOLO Helios: durante il DR il compute
# deve essere in esecuzione (lo scala promote-onprem.sh) e lo storage allineato
# (lo ripristina questo script). Il ripristino avviene quindi nel database
# `helios`, non nel database legacy `helpdesk`.
#
# Formato del backup: pg_dump custom (`.dump`), lo stesso prodotto dal CronJob di
# backup del primario (infra/aws/kubernetes/backup-cronjob.yaml). Il ripristino
# usa pg_restore, non psql su SQL plain: e' l'unico formato della catena
# backup -> mirror -> restore, cosi' produttore e consumatore combaciano.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/../common/lib.sh"

require_ansible_coordinator

HELIOS_DR_NAMESPACE="${HELIOS_DR_NAMESPACE:-helios-desk}"
HELIOS_DR_WORKLOADS="${HELIOS_DR_WORKLOADS:-helios-ticket-service helios-automation-service helios-bff helios-web}"
HELIOS_APP_DB_SECRET="${HELIOS_APP_DB_SECRET:-helios-app-database}"

backup_key="${1:-}"
mirror_dir="${BACKUP_MIRROR_DIR}/${BACKUP_S3_PREFIX}"
if [ -z "${backup_key}" ]; then
  if [ -d "${mirror_dir}" ]; then
    backup_key="$(find "${mirror_dir}" -maxdepth 1 -type f -name '*.dump' -printf '%T@ %f\n' | sort -nr | head -n 1 | cut -d' ' -f2-)"
  fi
fi

if [ -z "${backup_key}" ]; then
  echo "No PostgreSQL custom-format backup (*.dump) found in the on-prem mirror ${mirror_dir}." >&2
  exit 1
fi

if [[ "${backup_key}" != */* ]]; then
  backup_key="${BACKUP_S3_PREFIX}/${backup_key}"
fi

restore_dir="$(mktemp -d "$(runtime_dir)/restore.XXXXXX")"
trap 'rm -rf "${restore_dir}"' EXIT
archive_name="${backup_key##*/}"
archive_path="${restore_dir}/${archive_name}"
checksum_path="${archive_path}.sha256"

mirror_archive="${mirror_dir}/${archive_name}"
mirror_checksum="${mirror_archive}.sha256"
if [ ! -s "${mirror_archive}" ] || [ ! -s "${mirror_checksum}" ]; then
  echo "Backup or checksum missing from the on-prem mirror: ${archive_name}" >&2
  exit 1
fi
cp "${mirror_archive}" "${archive_path}"
cp "${mirror_checksum}" "${checksum_path}"

(
  cd "${restore_dir}"
  sha256sum -c "${archive_name}.sha256"
)

if [ ! -s "${archive_path}" ]; then
  echo "Restore archive is empty: ${backup_key}" >&2
  exit 1
fi

# Stesso vincolo di ordine di deploy-lambda-onprem.sh: `lxc file push` non avvia
# il container, quindi un push a container spento finisce in un /tmp che il boot
# ripulisce e il restore fallirebbe con "no such file". Avviare e attendere k3s
# prima del push. /var/tmp non e' soggetto a pulizia automatica.
wait_for_k3s "${ONPREM_K3S_NAME}" exec_onprem

lxc_retry file push "${archive_path}" "${ONPREM_K3S_NAME}/var/tmp/helios-restore.dump"

# Nessuno deve scrivere sul database mentre viene ripristinato. I workload Helios
# sono gia' a zero repliche a riposo, ma il restore puo' essere rieseguito dopo
# una promozione parziale: azzerarli qui rende lo script sicuro da ripetere.
if exec_onprem kubectl get namespace "${HELIOS_DR_NAMESPACE}" >/dev/null 2>&1; then
  read -r -a helios_workloads <<<"${HELIOS_DR_WORKLOADS}"
  for workload in "${helios_workloads[@]}"; do
    if ! [[ "${workload}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
      echo "Invalid Kubernetes deployment name in HELIOS_DR_WORKLOADS." >&2
      exit 1
    fi
    exec_onprem kubectl -n "${HELIOS_DR_NAMESPACE}" scale \
      "deployment/${workload}" --replicas=0 >/dev/null
    wait_for_deployment_stopped exec_onprem "${HELIOS_DR_NAMESPACE}" "${workload}"
  done
fi

exec_onprem kubectl -n "${APP_NAMESPACE}" rollout status deployment/postgres --timeout=180s
pod="$(exec_onprem kubectl -n "${APP_NAMESPACE}" get pod -l app=postgres -o jsonpath='{.items[0].metadata.name}')"

# Il nome del database applicativo e' la fonte di verita' del contratto: viene
# dal Secret `helios-app-database` (chiave DATABASE_URL), non hardcodato. Cosi'
# il restore segue sempre il database che l'app usa davvero.
helios_db="${HELIOS_APP_DB:-}"
if [ -z "${helios_db}" ]; then
  db_url="$(exec_onprem kubectl -n "${HELIOS_DR_NAMESPACE}" get secret "${HELIOS_APP_DB_SECRET}" \
    -o jsonpath='{.data.DATABASE_URL}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  if [ -n "${db_url}" ]; then
    helios_db="${db_url##*/}"
    helios_db="${helios_db%%\?*}"
  fi
fi
helios_db="${helios_db:-helios}"

for postgres_identifier in "${POSTGRES_USER}" "${POSTGRES_DB}" "${helios_db}"; do
  if ! [[ "${postgres_identifier}" =~ ^[a-z_][a-z0-9_]{0,62}$ ]]; then
    echo "Invalid PostgreSQL identifier in restore configuration." >&2
    exit 1
  fi
done

# Guardia coerente con seed-secrets.sh: il sito DR non deve mai ripristinare nel
# database legacy `helpdesk`, che ha lo schema del monolite rimosso.
if [ "${helios_db}" = "helpdesk" ] || [ "${helios_db}" = "${POSTGRES_DB}" ]; then
  echo "Il restore Helios non deve puntare al database legacy '${helios_db}'." >&2
  exit 1
fi

exec_onprem kubectl -n "${APP_NAMESPACE}" cp \
  /var/tmp/helios-restore.dump "${pod}:/tmp/helios-restore.dump"

# Creazione del database (se manca) e restore in un unico script passato via
# stdin a `sh -s` nel pod: evita il quoting annidato host -> lxc -> kubectl ->
# psql, e usa `lxc exec` diretto invece di exec_onprem perche' i retry di
# lxc_retry consumerebbero lo stdin al primo tentativo. Il container e' gia'
# avviato (wait_for_k3s piu' sopra), quindi non serve ensure_container_started.
#
# pg_restore: --clean --if-exists rende il restore idempotente (droppa gli
# oggetti esistenti prima di ricrearli, senza errori su un database vuoto);
# --no-owner/--no-acl perche' i ruoli del primario non esistono necessariamente
# sul sito DR; --exit-on-error fa fallire il playbook su un restore parziale
# invece di promuovere un sito con dati incompleti.
lxc exec "${ONPREM_K3S_NAME}" -- kubectl -n "${APP_NAMESPACE}" exec -i "${pod}" -- \
  sh -s -- "${POSTGRES_USER}" "${POSTGRES_DB}" "${helios_db}" <<'EOF'
set -eu
postgres_user="$1"
admin_db="$2"
target_db="$3"
if ! psql -U "${postgres_user}" -d "${admin_db}" -tAc \
  "SELECT 1 FROM pg_database WHERE datname='${target_db}'" | grep -q 1; then
  psql -U "${postgres_user}" -d "${admin_db}" \
    -c "CREATE DATABASE \"${target_db}\" OWNER \"${postgres_user}\""
fi
pg_restore --clean --if-exists --no-owner --no-acl --exit-on-error \
  -U "${postgres_user}" -d "${target_db}" /tmp/helios-restore.dump
EOF

# Il dump e' un estratto completo del database: non va lasciato sul nodo ne'
# dentro il pod dopo il restore.
exec_onprem rm -f /var/tmp/helios-restore.dump
exec_onprem kubectl -n "${APP_NAMESPACE}" exec "${pod}" -- \
  rm -f /tmp/helios-restore.dump || true

echo "Restored on-prem database '${helios_db}' from mirrored backup ${mirror_archive}"
