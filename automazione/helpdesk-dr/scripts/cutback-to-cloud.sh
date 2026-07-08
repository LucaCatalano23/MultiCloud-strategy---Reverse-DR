#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

set_helpdesk_dns "${CLOUD_K3S_IP}"
"${SCRIPT_DIR}/demote-onprem.sh"

echo "Cutback complete. ${HELPDESK_FQDN} -> ${CLOUD_K3S_IP}"
