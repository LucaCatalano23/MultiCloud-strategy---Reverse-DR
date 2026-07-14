#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/../common/lib.sh"

require_ansible_coordinator

backup_key="${1:-}"
mirror_dir="${BACKUP_MIRROR_DIR}/${BACKUP_S3_PREFIX}"
if [ -z "${backup_key}" ]; then
  if [ -d "${mirror_dir}" ]; then
    backup_key="$(find "${mirror_dir}" -maxdepth 1 -type f -name 'helpdesk-*.sql.gz' -printf '%T@ %f\n' | sort -nr | head -n 1 | cut -d' ' -f2-)"
  fi
fi

if [ -z "${backup_key}" ]; then
  echo "No PostgreSQL backup found in the on-prem mirror ${mirror_dir}." >&2
  exit 1
fi

if [[ "${backup_key}" != */* ]]; then
  backup_key="${BACKUP_S3_PREFIX}/${backup_key}"
fi

restore_dir="$(mktemp -d "${ROOT_DIR}/.restore.XXXXXX")"
trap 'rm -rf "${restore_dir}"' EXIT
archive_name="${backup_key##*/}"
archive_path="${restore_dir}/${archive_name}"
checksum_path="${archive_path}.sha256"
sql_path="${restore_dir}/helpdesk-restore.sql"

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
gzip -dc "${archive_path}" >"${sql_path}"

if [ ! -s "${sql_path}" ]; then
  echo "Decompressed restore is empty: ${backup_key}" >&2
  exit 1
fi

lxc_retry file push "${sql_path}" "${ONPREM_K3S_NAME}/tmp/helpdesk-restore.sql"

wait_for_k3s "${ONPREM_K3S_NAME}" exec_onprem
exec_onprem kubectl -n "${APP_NAMESPACE}" scale deployment/helpdesk-api --replicas=0 || true
exec_onprem kubectl -n "${APP_NAMESPACE}" rollout status deployment/postgres --timeout=180s
pod="$(exec_onprem kubectl -n "${APP_NAMESPACE}" get pod -l app=postgres -o jsonpath='{.items[0].metadata.name}')"
exec_onprem sh -lc "kubectl -n ${APP_NAMESPACE} cp /tmp/helpdesk-restore.sql ${pod}:/tmp/helpdesk-restore.sql"
exec_onprem sh -lc "kubectl -n ${APP_NAMESPACE} exec ${pod} -- psql -U ${POSTGRES_USER} -d ${POSTGRES_DB} -c 'drop schema public cascade; create schema public;'"
exec_onprem sh -lc "kubectl -n ${APP_NAMESPACE} exec ${pod} -- psql -U ${POSTGRES_USER} -d ${POSTGRES_DB} -f /tmp/helpdesk-restore.sql"

echo "Restored on-prem from mirrored backup ${mirror_archive}"
