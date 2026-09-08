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
export AWS_EC2_METADATA_DISABLED=true
export AWS_DEFAULT_REGION="${AWS_REGION}"
export AWS_PAGER=""

# S3 path-style: nel lab l'endpoint virtual-host del bucket
# (<bucket>.s3.<region>.amazonaws.com) non e' raggiungibile attraverso l'edge del
# laboratorio, mentre l'endpoint regionale (s3.<region>.amazonaws.com/<bucket>)
# risponde. `addressing_style` non ha un env var, quindi lo scriviamo in un config
# temporaneo e ci puntiamo con AWS_CONFIG_FILE. BACKUP_S3_ADDRESSING_STYLE=virtual
# ripristina il virtual-host se in un altro ambiente l'edge lo raggiunge.
aws_config="$(mktemp)"
trap 'rm -f "${aws_config}"' EXIT
{
  printf '[default]\n'
  printf 'region = %s\n' "${AWS_REGION}"
  printf 's3 =\n'
  printf '    addressing_style = %s\n' "${BACKUP_S3_ADDRESSING_STYLE:-path}"
} >"${aws_config}"
export AWS_CONFIG_FILE="${aws_config}"

# Timeout espliciti: un percorso S3 irraggiungibile fallisce in fretta invece di
# tenere appeso il oneshot.
aws_args=(--cli-connect-timeout 10 --cli-read-timeout 30)
[ -n "${AWS_REGION:-}" ] && aws_args+=(--region "${AWS_REGION}")

s3_prefix="${BACKUP_S3_PREFIX}"
mirror_dir="${BACKUP_MIRROR_DIR}/${s3_prefix}"
mkdir -p "${mirror_dir}"
chmod 0700 "${mirror_dir}" 2>/dev/null || true

# 1) Elenca i dump su S3. Un fallimento qui interrompe SENZA prune: mirror intatto.
#    Lo stderr reale di aws (timeout, AccessDenied, DNS, bucket assente) finisce nel
#    journal invece di essere silenziato: il fail non e' piu' un generico "down".
s3_error_file="$(mktemp "$(runtime_dir)/s3-list-error.XXXXXX")"
trap 'rm -f "${s3_error_file}"' EXIT

if ! s3_listing="$(
  aws "${region_args[@]}" \
    s3api list-objects-v2 \
    --bucket "${BACKUP_S3_BUCKET}" \
    --prefix "${s3_prefix}/" \
    --query "Contents[].Key" \
    --output text \
    --cli-connect-timeout 10 \
    --cli-read-timeout 30 \
    --no-cli-pager \
    2>"${s3_error_file}"
)"; then
  echo "Cannot list s3://${BACKUP_S3_BUCKET}/${s3_prefix}/; mirror left untouched." >&2
  cat "${s3_error_file}" >&2
  exit 1
fi

rm -f "${s3_error_file}"
trap - EXIT

if [ -z "${s3_listing}" ] || [ "${s3_listing}" = "None" ]; then
  echo "No backup objects found under s3://${BACKUP_S3_BUCKET}/${s3_prefix}/; mirror left untouched."
  exit 0
fi

mapfile -t newest < <(
  printf '%s\n' "${s3_listing}" |
    tr '\t' '\n' |
    sed "s#^${s3_prefix}/##" |
    grep -E '^[0-9]{8}T[0-9]{6}Z\.dump$' |
    sort -r |
    head -n "${retention}"
)

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
  if aws "${aws_args[@]}" s3 cp \
      "s3://${BACKUP_S3_BUCKET}/${s3_prefix}/${dump}" "${tmp}/${dump}" --only-show-errors \
    && aws "${aws_args[@]}" s3 cp \
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
