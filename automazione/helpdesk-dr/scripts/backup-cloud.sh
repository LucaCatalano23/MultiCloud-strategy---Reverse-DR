#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup_name="helpdesk-${timestamp}.sql"

wait_for_k3s "${CLOUD_K3S_NAME}" exec_cloud
exec_cloud install -d "${BACKUP_DIR}"
pod="$(exec_cloud kubectl -n "${APP_NAMESPACE}" get pod -l app=postgres -o jsonpath='{.items[0].metadata.name}')"
exec_cloud sh -lc "kubectl -n ${APP_NAMESPACE} exec ${pod} -- pg_dump -U ${POSTGRES_USER} ${POSTGRES_DB} > ${BACKUP_DIR}/${backup_name}"
exec_cloud sh -lc "cd ${BACKUP_DIR} && ls -1t helpdesk-*.sql | tail -n +$((BACKUP_RETENTION + 1)) | xargs -r rm -f"

echo "Created cloud backup: ${BACKUP_DIR}/${backup_name}"

