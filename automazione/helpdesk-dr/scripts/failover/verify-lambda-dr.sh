#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/../common/lib.sh"

require_ansible_coordinator
wait_for_k3s "${ONPREM_K3S_NAME}" exec_onprem
exec_onprem kubectl -n lambda-dr rollout status deployment/event-adapter --timeout=120s
exec_onprem kubectl -n lambda-dr rollout status deployment/lambda-helpdesk-ticket-processor --timeout=120s

adapter_addresses="$(exec_onprem kubectl -n lambda-dr get endpoints event-adapter -o jsonpath='{.subsets[0].addresses[*].ip}')"
runtime_addresses="$(exec_onprem kubectl -n lambda-dr get endpoints lambda-helpdesk-ticket-processor -o jsonpath='{.subsets[0].addresses[*].ip}')"

if [ -z "${adapter_addresses}" ] || [ -z "${runtime_addresses}" ]; then
  echo "Lambda DR services do not have ready endpoints." >&2
  exit 1
fi

echo "Lambda DR ready: adapter=${adapter_addresses}, runtime=${runtime_addresses}"

