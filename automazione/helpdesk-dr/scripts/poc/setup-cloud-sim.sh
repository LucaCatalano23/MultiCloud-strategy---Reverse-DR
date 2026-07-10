#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/../common/lib.sh"

if ! lxc_retry network show "${CLOUD_NET}" >/dev/null 2>&1; then
  lxc_retry network create "${CLOUD_NET}" \
    ipv4.address="${CLOUD_NET_CIDR}" \
    ipv4.nat=true \
    ipv4.dhcp=true \
    ipv6.address=none
fi

if ! lxc_retry info "${CLOUD_K3S_NAME}" >/dev/null 2>&1; then
  lxc_retry init ubuntu:24.04 "${CLOUD_K3S_NAME}"
  if lxc_retry config device show "${CLOUD_K3S_NAME}" | grep -q '^eth0:'; then
    lxc_retry config device remove "${CLOUD_K3S_NAME}" eth0
  fi
fi

configure_lxc_k3s_container "${CLOUD_K3S_NAME}"

if ! lxc_retry config device show "${CLOUD_K3S_NAME}" | grep -q '^eth0:'; then
  lxc_retry network attach "${CLOUD_NET}" "${CLOUD_K3S_NAME}" eth0 eth0
fi
lxc_retry config device set "${CLOUD_K3S_NAME}" eth0 ipv4.address "${CLOUD_K3S_IP}"

if ! container_running "${CLOUD_K3S_NAME}"; then
  lxc_retry start "${CLOUD_K3S_NAME}"
fi

exec_cloud cloud-init status --wait
exec_cloud sh -lc "printf 'Acquire::ForceIPv4 \"true\";\n' >/etc/apt/apt.conf.d/99force-ipv4"
exec_cloud apt-get update
exec_cloud env DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates iproute2 postgresql-client git
exec_cloud install -d "${BACKUP_DIR}"
prepare_lxc_for_k3s exec_cloud

install_k3s_if_missing "${CLOUD_K3S_NAME}" exec_cloud
exec_cloud systemctl restart k3s
wait_for_k3s "${CLOUD_K3S_NAME}" exec_cloud

echo "cloud-sim ready: ${CLOUD_K3S_NAME} ${CLOUD_K3S_IP}"
