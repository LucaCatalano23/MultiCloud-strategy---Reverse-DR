#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

check() {
  local description="$1"
  shift
  printf '%-44s' "${description}"
  if "$@" >/tmp/helpdesk-dr-check.log 2>&1; then
    echo "OK"
  else
    echo "FAIL"
    cat /tmp/helpdesk-dr-check.log
    exit 1
  fi
}

check "cloud k3s nodes" exec_cloud kubectl get nodes
check "on-prem k3s nodes" exec_onprem kubectl get nodes
check "cloud helpdesk live" exec_cloud curl -fsS -H "Host: ${HELPDESK_FQDN}" "http://127.0.0.1/health/live"
if [ "$(read_dr_state)" = "dr" ]; then
  check "on-prem helpdesk ready" onprem_ready
else
  check "cloud helpdesk ready" cloud_ready
fi
check "dns resolves helpdesk" exec_dns dig +short "${HELPDESK_FQDN}"
check "ansible sees helpdesk dns" exec_ansible dig +short "@${DNS_SERVER_IP}" "${HELPDESK_FQDN}"

echo "Helpdesk DR checks passed."
