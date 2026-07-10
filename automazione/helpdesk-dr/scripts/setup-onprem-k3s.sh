#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

if ! lxc_retry info "${ONPREM_K3S_NAME}" >/dev/null 2>&1; then
  echo "Missing on-prem container ${ONPREM_K3S_NAME}. Run automazione/lxc-lab/setup.sh first." >&2
  exit 1
fi

if ! container_running "${ONPREM_K3S_NAME}"; then
  configure_lxc_k3s_container "${ONPREM_K3S_NAME}"
  lxc_retry start "${ONPREM_K3S_NAME}"
else
  configure_lxc_k3s_container "${ONPREM_K3S_NAME}"
  if ! lxc_retry config get "${ONPREM_K3S_NAME}" security.privileged | grep -q '^true$'; then
    cat >&2 <<EOF
${ONPREM_K3S_NAME} is already running but is not privileged.
k3s inside LXC is more reliable with security.privileged=true.
Stop the container or rerun automazione/lxc-lab/setup.sh from a clean state if k3s fails.
EOF
  fi
fi

exec_onprem cloud-init status --wait
exec_onprem sh -lc "printf 'Acquire::ForceIPv4 \"true\";\n' >/etc/apt/apt.conf.d/99force-ipv4"
exec_onprem apt-get update
exec_onprem env DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates iproute2 postgresql-client git
exec_onprem install -d "${BACKUP_DIR}"
prepare_lxc_for_k3s exec_onprem

install_k3s_if_missing "${ONPREM_K3S_NAME}" exec_onprem
exec_onprem systemctl restart k3s
wait_for_k3s "${ONPREM_K3S_NAME}" exec_onprem

echo "on-prem k3s ready: ${ONPREM_K3S_NAME} ${ONPREM_K3S_IP}"
