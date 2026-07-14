#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/../common/lib.sh"

require_ansible_coordinator

wait_for_k3s "${ONPREM_K3S_NAME}" exec_onprem
exec_onprem kubectl -n "${APP_NAMESPACE}" scale deployment/helpdesk-api --replicas=1
exec_onprem kubectl -n "${APP_NAMESPACE}" set env deployment/helpdesk-api DR_ACTIVE=true
exec_onprem kubectl -n "${APP_NAMESPACE}" rollout status deployment/helpdesk-api --timeout=180s
onprem_ready
set_helpdesk_dns "${ONPREM_K3S_IP}"
write_dr_state "dr"

echo "On-prem promoted. ${HELPDESK_FQDN} -> ${ONPREM_K3S_IP}"
