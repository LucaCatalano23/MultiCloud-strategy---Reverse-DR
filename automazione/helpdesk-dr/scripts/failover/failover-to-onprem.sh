#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/../common/lib.sh"

bash "${SCRIPT_DIR}/../restore/restore-onprem.sh"
bash "${SCRIPT_DIR}/promote-onprem.sh"

echo "Failover complete. ${HELPDESK_FQDN} -> ${ONPREM_K3S_IP}"
