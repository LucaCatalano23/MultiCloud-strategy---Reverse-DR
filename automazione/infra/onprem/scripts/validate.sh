#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ONPREM_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
KUBECTL_BIN="${KUBECTL:-kubectl}"

if [ -d "${ONPREM_DIR}/../../helpdesk-dr" ]; then
  HELPDESK_DR_DIR="$(cd "${ONPREM_DIR}/../../helpdesk-dr" && pwd)"
elif [ -d "${ONPREM_DIR}/../../ansible" ]; then
  HELPDESK_DR_DIR="$(cd "${ONPREM_DIR}/../.." && pwd)"
else
  echo "Cannot locate the helpdesk-dr integration directory." >&2
  exit 1
fi

python3 "${ONPREM_DIR}/tests/validate_onprem.py"
"${KUBECTL_BIN}" kustomize "${ONPREM_DIR}" >/dev/null

bash -n \
  "${ONPREM_DIR}/scripts/create-secrets.sh" \
  "${ONPREM_DIR}/scripts/apply-migrations.sh" \
  "${ONPREM_DIR}/scripts/provision-dr-operator.sh" \
  "${ONPREM_DIR}/keycloak/provision/provision-dr-operator.sh" \
  "${HELPDESK_DR_DIR}/scripts/deploy/deploy-onprem-standby.sh" \
  "${HELPDESK_DR_DIR}/scripts/failover/promote-onprem.sh" \
  "${HELPDESK_DR_DIR}/scripts/failover/demote-onprem.sh"

if command -v ansible-playbook >/dev/null 2>&1; then
  (
    cd "${HELPDESK_DR_DIR}"
    ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook \
      -i ansible/inventory.ini \
      ansible/playbooks/failover.yml \
      --syntax-check
  )
else
  echo "ansible-playbook not found; skipped syntax check." >&2
fi

echo "On-prem static validation passed."
