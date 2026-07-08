#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

if exec_onprem kubectl -n "${APP_NAMESPACE}" get deployment/helpdesk-api >/dev/null 2>&1; then
  pod="$(exec_onprem kubectl -n "${APP_NAMESPACE}" get pod -l app=helpdesk-api -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [ -n "${pod}" ]; then
    exec_onprem sh -lc "kubectl -n ${APP_NAMESPACE} exec ${pod} -- rm -f /dr-state/ready" || true
  fi
  exec_onprem kubectl -n "${APP_NAMESPACE}" scale deployment/helpdesk-api --replicas="${ONPREM_STANDBY_REPLICAS:-1}" || true
fi

write_dr_state "primary"
echo "On-prem demoted to standby."
