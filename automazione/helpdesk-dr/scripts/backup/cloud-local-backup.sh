#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../../config.env
source "${ROOT_DIR}/config.env"

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup_name="helpdesk-${timestamp}.sql.gz"
backup_path="${BACKUP_DIR}/${backup_name}"
checksum_path="${backup_path}.sha256"

: "${LOCALSTACK_ENDPOINT:?LOCALSTACK_ENDPOINT must point to the LocalStack gateway}"
: "${BACKUP_S3_BUCKET:?BACKUP_S3_BUCKET is required}"
: "${BACKUP_S3_PREFIX:?BACKUP_S3_PREFIX is required}"

install -d "${BACKUP_DIR}"
pod="$(kubectl -n "${APP_NAMESPACE}" get pod -l app=postgres -o jsonpath='{.items[0].metadata.name}')"
kubectl -n "${APP_NAMESPACE}" exec "${pod}" -- \
  pg_dump -U "${POSTGRES_USER}" "${POSTGRES_DB}" | gzip -9 >"${backup_path}"

if [ ! -s "${backup_path}" ]; then
  echo "Backup is empty: ${backup_path}" >&2
  exit 1
fi

cd "${BACKUP_DIR}"
sha256sum "${backup_name}" >"${backup_name}.sha256"

AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}" \
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}" \
AWS_DEFAULT_REGION="${AWS_REGION:-eu-west-1}" \
  aws --endpoint-url "${LOCALSTACK_ENDPOINT}" s3 cp \
  "${backup_path}" "s3://${BACKUP_S3_BUCKET}/${BACKUP_S3_PREFIX}/${backup_name}"

AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}" \
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}" \
AWS_DEFAULT_REGION="${AWS_REGION:-eu-west-1}" \
  aws --endpoint-url "${LOCALSTACK_ENDPOINT}" s3 cp \
  "${checksum_path}" "s3://${BACKUP_S3_BUCKET}/${BACKUP_S3_PREFIX}/${backup_name}.sha256"

mapfile -t expired < <(ls -1t helpdesk-*.sql.gz 2>/dev/null | tail -n +"$((BACKUP_RETENTION + 1))")
for expired_backup in "${expired[@]}"; do
  rm -f "${expired_backup}" "${expired_backup}.sha256"
done

echo "Created and uploaded cloud backup: s3://${BACKUP_S3_BUCKET}/${BACKUP_S3_PREFIX}/${backup_name}"
