#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

if lxc_retry info "${CLOUD_K3S_NAME}" >/dev/null 2>&1; then
  lxc_retry delete --force "${CLOUD_K3S_NAME}"
fi

if lxc_retry network show "${CLOUD_NET}" >/dev/null 2>&1; then
  lxc_retry network delete "${CLOUD_NET}"
fi

echo "cloud-sim removed."

