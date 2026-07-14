#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/../common/lib.sh"

require_ansible_coordinator

if exec_onprem kubectl -n "${APP_NAMESPACE}" get deployment/helpdesk-api >/dev/null 2>&1; then
  exec_onprem kubectl -n "${APP_NAMESPACE}" set env deployment/helpdesk-api DR_ACTIVE=false || true
  exec_onprem kubectl -n "${APP_NAMESPACE}" scale deployment/helpdesk-api --replicas="${ONPREM_STANDBY_REPLICAS:-1}" || true
fi

write_dr_state "primary"
echo "On-prem demoted to standby."
