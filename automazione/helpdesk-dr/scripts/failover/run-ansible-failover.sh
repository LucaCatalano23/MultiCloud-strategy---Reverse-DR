#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/../common/lib.sh"

require_ansible_coordinator
backup_key="${1:-}"
args=(
  -i "${ROOT_DIR}/ansible/inventory.ini"
  "${ROOT_DIR}/ansible/playbooks/failover.yml"
)
if [ -n "${backup_key}" ]; then
  args+=(--extra-vars "backup_key=${backup_key}")
fi

ANSIBLE_CONFIG="${ROOT_DIR}/ansible/ansible.cfg" ansible-playbook "${args[@]}"

