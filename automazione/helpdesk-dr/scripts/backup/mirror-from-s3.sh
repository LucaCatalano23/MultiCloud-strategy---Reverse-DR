#!/usr/bin/env bash
# Sincronizza nel mirror on-prem gli ultimi backup Postgres che il CronJob del
# primario (infra/aws/kubernetes/backup-cronjob.yaml) pubblica su S3, e tiene solo
# i piu' recenti. Gira ogni 2 minuti via systemd timer su ansible-node
# (helpdesk-dr-backup-mirror.timer): e' il "check sulla presenza di backup in
# cloud" che alimenta restore-onprem.sh, e sostituisce il trasporto manuale del
# mirror.
#
# Sicurezza deliberata:
#   - se S3 non e' raggiungibile (primario/rete giu'), lo script FALLISCE senza
#     toccare il mirror: l'ultimo backup buono resta per il failover. Il prune
#     avviene solo DOPO un list riuscito, e sui file realmente presenti;
#   - ogni download e' accettato solo se il suo checksum combacia; il .sha256 del
#     mirror e' normalizzato a basename (il CronJob ci scrive il path assoluto del
#     pod), cosi' il `sha256sum -c` di restore-onprem.sh funziona;
#   - credenziali AWS lette da config.env (env), mai in argv, umask 077. Il sito
#     DR usa una credenziale AWS SOLO in lettura sul bucket dei backup (vedi la
#     nota di reversal in config.env.example e infra/onprem/README.md).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/lib.sh
source "${SCRIPT_DIR}/../common/lib.sh"

umask 077

# Le credenziali arrivano da config.env (sourced da lib.sh) come variabili di
# shell: vanno esportate perche' la CLI `aws`, processo figlio, le veda. Se non ci
# sono, si ricade sulla catena di default di aws (profilo, IAM Roles Anywhere).
for _aws_var in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN \
  AWS_REGION AWS_DEFAULT_REGION AWS_PROFILE; do
  if [ -n "${!_aws_var:-}" ]; then export "${_aws_var?}"; fi
done

: "${BACKUP_S3_BUCKET:?BACKUP_S3_BUCKET must point to the primary backup bucket}"
retention="${BACKUP_MIRROR_RETENTION:-2}"
if ! [[ "${retention}" =~ ^[1-9][0-9]*$ ]]; then
  echo "BACKUP_MIRROR_RETENTION must be a positive integer." >&2
  exit 1
fi

if ! command -v aws >/dev/null 2>&1; then
  echo "aws CLI not found on the coordinator; cannot mirror S3 backups." >&2
  exit 1
fi

s3_prefix="${BACKUP_S3_PREFIX}"
mirror_dir="${BACKUP_MIRROR_DIR}/${s3_prefix}"
mkdir -p "${mirror_dir}"
chmod 0700 "${mirror_dir}" 2>/dev/null || true

region_args=()
[ -n "${AWS_REGION:-}" ] && region_args=(--region "${AWS_REGION}")

# 1) Elenca i dump su S3. Un fallimento qui interrompe SENZA prune: mirror intatto.
if ! s3_listing="$(aws "${region_args[@]}" s3 ls \
  "s3://${BACKUP_S3_BUCKET}/${s3_prefix}/" 2>/dev/null)"; then
  echo "Cannot list s3://${BACKUP_S3_BUCKET}/${s3_prefix}/ (primary/network down?);" \
    "mirror left untouched." >&2
  exit 1
fi

# I nomi sono <stamp>.dump con stamp UTC ordinabile lessicograficamente: i piu'
# recenti sono in coda all'ordinamento crescente, quindi sort -r + head.
mapfile -t newest < <(printf '%s\n' "${s3_listing}" \
  | awk '{print $NF}' \
  | grep -E '\.dump$' \
  | sort -r \
  | head -n "${retention}")

if [ "${#newest[@]}" -eq 0 ]; then
  echo "No *.dump backups under s3://${BACKUP_S3_BUCKET}/${s3_prefix}/; nothing to mirror." >&2
  exit 1
fi

# 2) Scarica i mancanti (dump + .sha256) e accetta solo se il checksum combacia.
for dump in "${newest[@]}"; do
  local_dump="${mirror_dir}/${dump}"
  local_sum="${local_dump}.sha256"
  if [ -s "${local_dump}" ] && [ -s "${local_sum}" ] \
    && (cd "${mirror_dir}" && sha256sum -c "${dump}.sha256" >/dev/null 2>&1); then
    continue # gia' presente e integro
  fi
  tmp="$(mktemp -d "${mirror_dir}/.sync.XXXXXX")"
  if aws "${region_args[@]}" s3 cp \
      "s3://${BACKUP_S3_BUCKET}/${s3_prefix}/${dump}" "${tmp}/${dump}" --only-show-errors \
    && aws "${region_args[@]}" s3 cp \
      "s3://${BACKUP_S3_BUCKET}/${s3_prefix}/${dump}.sha256" "${tmp}/${dump}.sha256" --only-show-errors; then
    expected="$(awk 'NR==1{print $1}' "${tmp}/${dump}.sha256")"
    actual="$(sha256sum "${tmp}/${dump}" | awk '{print $1}')"
    if [ -n "${expected}" ] && [ "${expected}" = "${actual}" ]; then
      # Normalizza il checksum a basename per restore-onprem.sh (`sha256sum -c`).
      printf '%s  %s\n' "${actual}" "${dump}" >"${tmp}/${dump}.sha256"
      mv -f "${tmp}/${dump}" "${local_dump}"
      mv -f "${tmp}/${dump}.sha256" "${local_sum}"
      echo "Mirrored ${dump}"
    else
      echo "Skipped ${dump}: checksum mismatch." >&2
    fi
  else
    echo "Skipped ${dump}: S3 download failed." >&2
  fi
  rm -rf "${tmp}"
done

# 3) Prune sui file REALMENTE presenti: tiene gli N piu' recenti, elimina gli
#    altri. Basandosi sul presente (non sull'elenco S3) un download fallito del
#    piu' recente non fa mai scendere il mirror sotto la retention.
mapfile -t present < <(find "${mirror_dir}" -maxdepth 1 -type f -name '*.dump' -printf '%f\n' | sort -r)
index=0
for existing in "${present[@]}"; do
  index=$((index + 1))
  if [ "${index}" -gt "${retention}" ]; then
    rm -f "${mirror_dir}/${existing}" "${mirror_dir}/${existing}.sha256"
    echo "Pruned ${existing}"
  fi
done

# Rimuovi eventuali .sha256 orfani (senza il .dump corrispondente).
find "${mirror_dir}" -maxdepth 1 -type f -name '*.dump.sha256' -printf '%f\n' \
  | while read -r sumfile; do
      [ -f "${mirror_dir}/${sumfile%.sha256}" ] || rm -f "${mirror_dir}/${sumfile}"
    done

echo "Mirror sync complete: kept the newest ${retention} backup(s) in ${mirror_dir}."
