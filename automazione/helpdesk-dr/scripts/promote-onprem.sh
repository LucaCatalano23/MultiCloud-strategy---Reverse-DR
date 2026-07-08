#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

wait_for_k3s "${ONPREM_K3S_NAME}" exec_onprem
exec_onprem kubectl -n "${APP_NAMESPACE}" scale deployment/helpdesk-api --replicas=1
pod="$(wait_for_deployment_pod exec_onprem app=helpdesk-api)"
wait_for_pod_running exec_onprem "${pod}"
exec_onprem sh -lc "kubectl -n ${APP_NAMESPACE} exec ${pod} -- sh -lc 'mkdir -p /dr-state && touch /dr-state/ready'"
exec_onprem kubectl -n "${APP_NAMESPACE}" rollout status deployment/helpdesk-api --timeout=180s
set_helpdesk_dns "${ONPREM_K3S_IP}"
write_dr_state "dr"

echo "On-prem promoted. ${HELPDESK_FQDN} -> ${ONPREM_K3S_IP}"
