#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/../common/lib.sh"

require_ansible_coordinator

failover_lock="$(runtime_dir)/failover.lock"
exec 8>"${failover_lock}"
if ! flock -n 8; then
  echo "A failover operation is already in progress." >&2
  exit 1
fi

if [ "$(read_dr_state)" != "dr" ]; then
  echo "Cutback requires the committed dr state." >&2
  exit 1
fi

if ! cloud_ready; then
  echo "Cloud primary is not ready; cutback refused." >&2
  exit 1
fi

set_primary_helpdesk_dns
if bash "${SCRIPT_DIR}/demote-onprem.sh"; then
  write_dr_state "primary"
else
  write_dr_state "reconcile"
  echo "Cloud DNS was selected but on-prem demotion failed; reconciliation is required." >&2
  exit 1
fi

echo "Cutback complete. ${HELPDESK_FQDN} -> ${CLOUD_DNS_TARGET:-${CLOUD_K3S_IP}}"
