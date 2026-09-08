#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=topology.env
source "${SCRIPT_DIR}/topology.env"

config_file="/etc/systemd/resolved.conf.d/lxc-lab-dns.conf"
fallback_config_file="/etc/systemd/resolved.conf.d/wsl-fallback-dns.conf"
resolver_file="/etc/resolv.conf"
resolver_backup="/etc/resolv.conf.lxc-lab-backup"
resolver_target="/run/systemd/resolve/stub-resolv.conf"
wsl_dns_tunnel_ip="${WSL_DNS_TUNNEL_IP:-10.255.255.254}"
mode="${1:-status}"

usage() {
  echo "Usage: $0 <enable | disable | status>" >&2
}

require_root() {
  [ "$(id -u)" -eq 0 ] || { echo 'Run this command with sudo; it changes the WSL host DNS configuration.' >&2; exit 1; }
}

verify_lab_dns() {
  command -v dig >/dev/null 2>&1 || { echo 'Install dnsutils on the WSL host first.' >&2; return 1; }
  dig +short "@${DNS_IP}" "server-dns.${LAB_DOMAIN}" | grep -qx "${DNS_IP}"
}

use_systemd_resolver() {
  local current_target
  [ -e "${resolver_target}" ] || { echo "systemd-resolved stub ${resolver_target} is missing." >&2; return 1; }
  current_target="$(readlink -f "${resolver_file}" 2>/dev/null || true)"
  [ "${current_target}" = "${resolver_target}" ] && return 0

  if [ ! -e "${resolver_backup}" ] && [ ! -L "${resolver_backup}" ] \
    && { [ -e "${resolver_file}" ] || [ -L "${resolver_file}" ]; }; then
    cp -a -- "${resolver_file}" "${resolver_backup}"
  fi
  rm -f -- "${resolver_file}"
  ln -s "${resolver_target}" "${resolver_file}"
}

restore_resolver() {
  if [ -e "${resolver_backup}" ] || [ -L "${resolver_backup}" ]; then
    rm -f -- "${resolver_file}"
    mv -- "${resolver_backup}" "${resolver_file}"
  fi
}

verify_host_resolution() {
  getent ahostsv4 "server-dns.${LAB_DOMAIN}" | awk '{print $1}' | grep -qx "${DNS_IP}"
}

ensure_wsl_fallback_dns() {
  install -d -m 0755 /etc/systemd/resolved.conf.d
  cat >"${fallback_config_file}" <<EOF
[Resolve]
FallbackDNS=${wsl_dns_tunnel_ip}
EOF
}

case "${mode}" in
  enable)
    require_root
    # `is-system-running` exits non-zero for the valid `degraded` state, which
    # is common in WSL. Query the manager itself instead of requiring "running".
    systemctl show --property=Version --value >/dev/null 2>&1 || { echo 'systemd is required to configure the WSL host DNS.' >&2; exit 1; }
    verify_lab_dns || { echo "LXC lab DNS ${DNS_IP} is not reachable; run lxc-lab/setup.sh first." >&2; exit 1; }
    install -d -m 0755 /etc/systemd/resolved.conf.d
    ensure_wsl_fallback_dns
    cat >"${config_file}" <<EOF
[Resolve]
DNS=${DNS_IP}
Domains=~.
EOF
    systemctl restart systemd-resolved
    use_systemd_resolver
    resolvectl flush-caches || true
    resolvectl query "server-dns.${LAB_DOMAIN}" >/dev/null
    if ! verify_host_resolution; then
      restore_resolver
      rm -f "${config_file}"
      systemctl restart systemd-resolved
      echo 'The WSL application resolver is not using systemd-resolved; previous DNS configuration restored.' >&2
      exit 1
    fi
    echo "WSL host DNS now uses the LXC lab server ${DNS_IP}."
    ;;
  disable)
    require_root
    rm -f "${config_file}"
    ensure_wsl_fallback_dns
    systemctl restart systemd-resolved
    restore_resolver
    resolvectl flush-caches || true
    echo 'Removed the LXC lab DNS override from the WSL host.'
    ;;
  status)
    if [ -f "${config_file}" ]; then
      echo "LXC lab DNS override is enabled (${DNS_IP})."
    else
      echo 'LXC lab DNS override is disabled.'
    fi
    echo "Application resolver: $(readlink -f "${resolver_file}" 2>/dev/null || echo unavailable)"
    echo "WSL fallback DNS: ${wsl_dns_tunnel_ip}"
    resolvectl status 2>/dev/null || true
    ;;
  *) usage; exit 1 ;;
esac
