#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../config.env
source "${ROOT_DIR}/config.env"

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup_name="helpdesk-${timestamp}.sql"

install -d "${BACKUP_DIR}"
pod="$(kubectl -n "${APP_NAMESPACE}" get pod -l app=postgres -o jsonpath='{.items[0].metadata.name}')"
kubectl -n "${APP_NAMESPACE}" exec "${pod}" -- pg_dump -U "${POSTGRES_USER}" "${POSTGRES_DB}" >"${BACKUP_DIR}/${backup_name}"
cd "${BACKUP_DIR}"
ls -1t helpdesk-*.sql | tail -n +"$((BACKUP_RETENTION + 1))" | xargs -r rm -f

echo "Created cloud backup: ${BACKUP_DIR}/${backup_name}"

