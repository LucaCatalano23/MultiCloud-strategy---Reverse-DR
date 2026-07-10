#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/../common/lib.sh"

backup_name="${1:-}"
if [ -z "${backup_name}" ]; then
  backup_name="$(exec_cloud sh -lc "ls -1t ${BACKUP_DIR}/helpdesk-*.sql | head -n 1")"
fi

if [ -z "${backup_name}" ]; then
  echo "No backup found on cloud." >&2
  exit 1
fi

local_backup="${ROOT_DIR}/.restore.sql"
rm -f "${local_backup}"
lxc_retry file pull "${CLOUD_K3S_NAME}${backup_name}" "${local_backup}"
lxc_retry file push "${local_backup}" "${ONPREM_K3S_NAME}/tmp/helpdesk-restore.sql"
rm -f "${local_backup}"

wait_for_k3s "${ONPREM_K3S_NAME}" exec_onprem
exec_onprem kubectl -n "${APP_NAMESPACE}" scale deployment/helpdesk-api --replicas=0 || true
exec_onprem kubectl -n "${APP_NAMESPACE}" rollout status deployment/postgres --timeout=180s
pod="$(exec_onprem kubectl -n "${APP_NAMESPACE}" get pod -l app=postgres -o jsonpath='{.items[0].metadata.name}')"
exec_onprem sh -lc "kubectl -n ${APP_NAMESPACE} cp /tmp/helpdesk-restore.sql ${pod}:/tmp/helpdesk-restore.sql"
exec_onprem sh -lc "kubectl -n ${APP_NAMESPACE} exec ${pod} -- psql -U ${POSTGRES_USER} -d ${POSTGRES_DB} -c 'drop schema public cascade; create schema public;'"
exec_onprem sh -lc "kubectl -n ${APP_NAMESPACE} exec ${pod} -- psql -U ${POSTGRES_USER} -d ${POSTGRES_DB} -f /tmp/helpdesk-restore.sql"

echo "Restored on-prem from ${backup_name}"

