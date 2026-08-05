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

exec_onprem kubectl get namespace "${HELIOS_DR_NAMESPACE}" >/dev/null
read -r -a helios_workloads <<<"${HELIOS_DR_WORKLOADS}"
for workload in "${helios_workloads[@]}"; do
  if ! [[ "${workload}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
    echo "Invalid Kubernetes deployment name in HELIOS_DR_WORKLOADS." >&2
    exit 1
  fi
  exec_onprem kubectl -n "${HELIOS_DR_NAMESPACE}" get \
    "deployment/${workload}" >/dev/null
  exec_onprem kubectl -n "${HELIOS_DR_NAMESPACE}" set env \
    "deployment/${workload}" DR_ACTIVE=false
  exec_onprem kubectl -n "${HELIOS_DR_NAMESPACE}" scale \
    "deployment/${workload}" --replicas="${HELIOS_DR_STANDBY_REPLICAS}"
  if [ "${HELIOS_DR_STANDBY_REPLICAS}" = "0" ]; then
    wait_for_deployment_stopped exec_onprem "${HELIOS_DR_NAMESPACE}" "${workload}"
  fi

  actual_replicas="$(exec_onprem kubectl -n "${HELIOS_DR_NAMESPACE}" get \
    "deployment/${workload}" -o jsonpath='{.spec.replicas}')"
  dr_active="$(exec_onprem kubectl -n "${HELIOS_DR_NAMESPACE}" get \
    "deployment/${workload}" \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="DR_ACTIVE")].value}')"
  if [ "${actual_replicas}" != "${HELIOS_DR_STANDBY_REPLICAS}" ] ||
    [ "${dr_active}" != "false" ]; then
    echo "Demotion verification failed for deployment/${workload}." >&2
    exit 1
  fi
done

echo "On-prem demoted to standby."
