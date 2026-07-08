#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=topology.env
source "${SCRIPT_DIR}/topology.env"

lxc_retry() {
  local attempt
  local max_attempts=4
  local delay=2

  for attempt in $(seq 1 "${max_attempts}"); do
    if lxc "$@"; then
      return 0
    fi
    if [ "${attempt}" -eq "${max_attempts}" ]; then
      return 1
    fi
    sleep "${delay}"
    delay=$((delay * 2))
  done
}

check() {
  local description="$1"
  shift
  printf '%-48s' "${description}"
  if "$@" >/tmp/lxc-lab-check.log 2>&1; then
    echo "OK"
  else
    echo "FAIL"
    cat /tmp/lxc-lab-check.log
    exit 1
  fi
}

check "ansible installed" lxc_retry exec ansible-node -- bash -lc 'command -v ansible && ansible --version'
check "dns resolves git-server" lxc_retry exec ansible-node -- dig +short "@${DNS_IP}" "git-server.${LAB_DOMAIN}"
check "git daemon exposes bare repo" lxc_retry exec ansible-node -- git ls-remote "git://10.10.3.70/infrastructure.git"
check "dipendenti reaches datacenter" lxc_retry exec pc-dipendente1 -- ping -c 2 10.10.3.70
check "datacenter reaches dns dmz" lxc_retry exec git-server -- ping -c 2 "${DNS_IP}"
check "openwrt router-dipendenti" lxc_retry exec router-dipendenti -- cat /etc/openwrt_release
check "router-dipendenti ip eth0" lxc_retry exec router-dipendenti -- ip -4 addr show dev eth0
check "router-dipendenti ip eth1" lxc_retry exec router-dipendenti -- ip -4 addr show dev eth1
check "openwrt router-datacenter" lxc_retry exec router-datacenter -- cat /etc/openwrt_release
check "router-datacenter ip eth0" lxc_retry exec router-datacenter -- ip -4 addr show dev eth0
check "router-datacenter ip eth1" lxc_retry exec router-datacenter -- ip -4 addr show dev eth1
check "openwrt router-dmz" lxc_retry exec router-dmz -- cat /etc/openwrt_release
check "router-dmz ip eth0" lxc_retry exec router-dmz -- ip -4 addr show dev eth0
check "router-dmz ip eth1" lxc_retry exec router-dmz -- ip -4 addr show dev eth1
check "openwrt router-edge" lxc_retry exec router-edge -- cat /etc/openwrt_release
check "router-edge ip eth0" lxc_retry exec router-edge -- ip -4 addr show dev eth0
check "router-edge ip eth1" lxc_retry exec router-edge -- ip -4 addr show dev eth1
check "outbound internet through edge" lxc_retry exec ansible-node -- curl -4 --head --max-time 10 http://example.com

echo "All checks passed."
