#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/../common/lib.sh"

require_ansible_coordinator

if ! cloud_ready; then
  echo "Cloud primary is not ready; cutback refused." >&2
  exit 1
fi

set_helpdesk_dns "${CLOUD_K3S_IP}"
bash "${SCRIPT_DIR}/demote-onprem.sh"

echo "Cutback complete. ${HELPDESK_FQDN} -> ${CLOUD_K3S_IP}"
