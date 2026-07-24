#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/../common/lib.sh"

require_ansible_coordinator

HELIOS_DR_NAMESPACE="${HELIOS_DR_NAMESPACE:-helios-desk}"
HELIOS_DR_WORKLOADS="${HELIOS_DR_WORKLOADS:-helios-ticket-service helios-automation-service helios-bff helios-web}"
HELIOS_DR_STANDBY_REPLICAS="${HELIOS_DR_STANDBY_REPLICAS:-0}"

if ! [[ "${HELIOS_DR_STANDBY_REPLICAS}" =~ ^[0-9]+$ ]]; then
  echo "HELIOS_DR_STANDBY_REPLICAS must be a non-negative integer." >&2
  exit 1
fi

if exec_onprem kubectl get namespace "${HELIOS_DR_NAMESPACE}" >/dev/null 2>&1; then
  read -r -a helios_workloads <<<"${HELIOS_DR_WORKLOADS}"
  for workload in "${helios_workloads[@]}"; do
    if exec_onprem kubectl -n "${HELIOS_DR_NAMESPACE}" get "deployment/${workload}" >/dev/null 2>&1; then
      exec_onprem kubectl -n "${HELIOS_DR_NAMESPACE}" set env \
        "deployment/${workload}" \
        DR_ACTIVE=false || true
      exec_onprem kubectl -n "${HELIOS_DR_NAMESPACE}" scale \
        "deployment/${workload}" \
        --replicas="${HELIOS_DR_STANDBY_REPLICAS}" || true
    fi
  done
fi

write_dr_state "primary"
echo "On-prem demoted to standby."
