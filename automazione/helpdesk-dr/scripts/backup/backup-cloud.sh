#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/../common/lib.sh"

wait_for_k3s "${CLOUD_K3S_NAME}" exec_cloud
copy_to_container "${CLOUD_K3S_NAME}" "${ROOT_DIR}" "/opt/helpdesk-dr"
endpoint="$(discover_localstack_endpoint exec_cloud)"
exec_cloud env \
  LOCALSTACK_ENDPOINT="${endpoint}" \
  BACKUP_S3_BUCKET="${BACKUP_S3_BUCKET}" \
  BACKUP_S3_PREFIX="${BACKUP_S3_PREFIX}" \
  AWS_REGION="${AWS_REGION}" \
  AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID}" \
  AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY}" \
  bash /opt/helpdesk-dr/scripts/backup/cloud-local-backup.sh
