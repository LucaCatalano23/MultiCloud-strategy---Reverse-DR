#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/../common/lib.sh"

require_ansible_coordinator

failover_lock="$(runtime_dir)/failover.lock"
exec 8>"${failover_lock}"
if ! flock -n 8; then
  echo "A failover operation is already in progress." >&2
  exit 1
fi

current_state="$(read_dr_state)"
case "${current_state}" in
  primary) ;;
  dr)
    echo "DR mode is already active; no second failover will be attempted." >&2
    exit 1
    ;;
  promoting)
    echo "A previous failover stopped while promoting; reconcile it before retrying." >&2
    exit 1
    ;;
  *)
    echo "Unknown DR state: ${current_state}" >&2
    exit 1
    ;;
esac

backup_key="${1:-}"
if [ -n "${backup_key}" ] && {
  ! [[ "${backup_key}" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] ||
    [[ "${backup_key}" == *".."* ]] || [[ "${backup_key}" == */ ]];
}; then
  echo "Invalid backup key." >&2
  exit 1
fi
args=(
  -i "${ROOT_DIR}/ansible/inventory.ini"
  "${ROOT_DIR}/ansible/playbooks/failover.yml"
)
if [ -n "${backup_key}" ]; then
  args+=(--extra-vars "{\"backup_key\":\"${backup_key}\"}")
fi

write_dr_state "promoting"
if ANSIBLE_CONFIG="${ROOT_DIR}/ansible/ansible.cfg" ansible-playbook "${args[@]}"; then
  write_dr_state "dr"
  echo "Failover committed in DR state."
else
  # Ansible may fail after workloads or DNS have already changed. Never infer
  # that the primary is authoritative and never retry automatically: an
  # operator must inspect both sites and reconcile the transition.
  write_dr_state "reconcile"
  exit 1
fi
