#!/usr/bin/env bash
set -euo pipefail

lxc_retry() {
  local attempt
  local max_attempts=4
  local delay=2

  for attempt in $(seq 1 "${max_attempts}"); do
    if lxc "$@"; then
      return 0
    fi
    if [ "${attempt}" -eq "${max_attempts}" ]; then
      echo "lxc $* failed after ${max_attempts} attempts" >&2
      return 1
    fi
    sleep "${delay}"
    delay=$((delay * 2))
  done
}

containers=(
  ansible-node
  git-server
  k3s-datacenter
  pc-dipendente1
  router-datacenter
  router-dipendenti
  router-dmz
  router-edge
  server-dns
  vault-openbao
)

echo "== LXD =="
lxc_retry version || true
lxc_retry info || true

echo
echo "== Networks =="
lxc_retry network list || true

echo
echo "== Instances =="
lxc_retry list || true

for container in "${containers[@]}"; do
  if lxc_retry info "${container}" >/dev/null 2>&1; then
    echo
    echo "== ${container} =="
    lxc_retry config show "${container}" --expanded || true
    lxc_retry info "${container}" --show-log || true
    lxc_retry exec "${container}" -- ip addr || true
    lxc_retry exec "${container}" -- ip route || true
    lxc_retry exec "${container}" -- uci show network || true
    lxc_retry exec "${container}" -- logread -e netifd || true
  fi
done
