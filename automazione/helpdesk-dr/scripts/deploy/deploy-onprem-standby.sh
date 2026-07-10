#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/../common/lib.sh"

wait_for_k3s "${ONPREM_K3S_NAME}" exec_onprem
copy_to_container "${ONPREM_K3S_NAME}" "${ROOT_DIR}" "/tmp/helpdesk-dr"
exec_onprem sh -lc "rm -rf /tmp/helpdesk-dr/manifests/kubernetes/onprem/app && mkdir -p /tmp/helpdesk-dr/manifests/kubernetes/onprem/app && cp /tmp/helpdesk-dr/app/main.py /tmp/helpdesk-dr/app/requirements.txt /tmp/helpdesk-dr/manifests/kubernetes/onprem/app/"

exec_onprem sh -lc "kubectl kustomize --load-restrictor=LoadRestrictionsNone /tmp/helpdesk-dr/manifests/kubernetes/onprem | kubectl apply -f -"
exec_onprem kubectl -n "${APP_NAMESPACE}" rollout status deployment/postgres --timeout=180s
exec_onprem kubectl -n "${APP_NAMESPACE}" scale deployment/helpdesk-api --replicas="${ONPREM_STANDBY_REPLICAS:-1}"
if [ "${ONPREM_STANDBY_REPLICAS:-1}" -gt 0 ]; then
  pod="$(wait_for_deployment_pod exec_onprem app=helpdesk-api)"
  wait_for_pod_running exec_onprem "${pod}"
fi

write_dr_state "primary"
echo "On-prem standby deployed with ${ONPREM_STANDBY_REPLICAS:-1} replica(s). Readiness remains disabled until promotion."
