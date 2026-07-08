#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=topology.env
source "${SCRIPT_DIR}/topology.env"

lxc_retry() {
  local attempt
  local max_attempts=6
  local delay=3

  for attempt in $(seq 1 "${max_attempts}"); do
    if lxc "$@"; then
      return 0
    fi
    if [ "${attempt}" -eq "${max_attempts}" ]; then
      echo "lxc $* failed after ${max_attempts} attempts" >&2
      return 1
    fi
    echo "lxc $* failed, retrying in ${delay}s (${attempt}/${max_attempts})..." >&2
    sleep "${delay}"
    delay=$((delay * 2))
  done
}

containers=(
  ansible-node
  egress-proxy
  git-server
  k3s-datacenter
  pc-dipendente1
  proxy-keycloak
  router-datacenter
  router-dipendenti
  router-dmz
  router-edge
  server-dns
)

for container in "${containers[@]}"; do
  if lxc_retry info "${container}" >/dev/null 2>&1; then
    lxc_retry delete --force "${container}"
  fi
done

for network in "${NET_DIPENDENTI}" "${NET_TRANSIT}" "${NET_DATACENTER}" "${NET_DMZ}"; do
  if lxc_retry network show "${network}" >/dev/null 2>&1; then
    lxc_retry network delete "${network}"
  fi
done

echo "LXC lab removed."
