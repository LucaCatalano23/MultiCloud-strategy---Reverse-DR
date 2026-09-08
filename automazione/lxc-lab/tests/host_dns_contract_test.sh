#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${ROOT_DIR}/host-dns.sh"

test -f "${script}"
grep -Fq 'systemd-resolved' "${script}"
grep -Fq 'DNS=${DNS_IP}' "${script}"
grep -Fq 'enable | disable | status' "${script}"
grep -Fq 'LXC_LAB_HOST_DNS' "${ROOT_DIR}/setup.sh"
grep -Fq 'systemctl show --property=Version' "${script}"
grep -Fq '/run/systemd/resolve/stub-resolv.conf' "${script}"
grep -Fq '/etc/resolv.conf.lxc-lab-backup' "${script}"
grep -Fq 'getent ahostsv4' "${script}"
grep -Fq '/etc/systemd/resolved.conf.d/wsl-fallback-dns.conf' "${script}"
grep -Fq 'WSL_DNS_TUNNEL_IP:-10.255.255.254' "${script}"
grep -Fq 'FallbackDNS=${wsl_dns_tunnel_ip}' "${script}"
grep -Fq 'response-policy { zone "rpz-helios"; };' "${ROOT_DIR}/setup.sh"
grep -Fq 'zone "rpz-helios"' "${ROOT_DIR}/setup.sh"
if grep -Fq 'zone "terna.it"' "${ROOT_DIR}/setup.sh"; then
  echo 'Lab setup must not become authoritative for terna.it; it would break company SSO hosts.' >&2
  exit 1
fi
if grep -Fq 'systemctl is-system-running' "${script}"; then
  echo 'Host DNS script rejects a degraded but working systemd instance.' >&2
  exit 1
fi

echo 'Host DNS integration contract passed.'
