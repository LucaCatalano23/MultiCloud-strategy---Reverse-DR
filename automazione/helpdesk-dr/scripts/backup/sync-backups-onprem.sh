#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/../common/lib.sh"

require_ansible_coordinator
target="${BACKUP_MIRROR_DIR}/${BACKUP_S3_PREFIX}"
install -d -m 0750 "${target}"
aws_local s3 sync \
  "s3://${BACKUP_S3_BUCKET}/${BACKUP_S3_PREFIX}/" \
  "${target}/" \
  --delete \
  --exclude '*' \
  --include 'helpdesk-*.sql.gz' \
  --include 'helpdesk-*.sql.gz.sha256'

latest="$(find "${target}" -maxdepth 1 -type f -name 'helpdesk-*.sql.gz' -printf '%T@ %f\n' | sort -nr | head -n 1 | cut -d' ' -f2-)"
if [ -z "${latest}" ]; then
  echo "The on-prem backup mirror is empty." >&2
  exit 1
fi

(
  cd "${target}"
  sha256sum -c "${latest}.sha256"

  mapfile -t expired < <(ls -1t helpdesk-*.sql.gz 2>/dev/null | tail -n +"$((BACKUP_RETENTION + 1))")
  for expired_backup in "${expired[@]}"; do
    rm -f "${expired_backup}" "${expired_backup}.sha256"
  done
)

echo "On-prem backup mirror updated and verified: ${target}/${latest}"
