#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${TERNA_DR_CONFIG_FILE:-/etc/terna-static-dr/config.env}"
[ -r "${CONFIG_FILE}" ] || { echo "Missing configuration: ${CONFIG_FILE}" >&2; exit 1; }
# shellcheck disable=SC1090
source "${CONFIG_FILE}"

mode="${1:-watch}"
state_dir="${TERNA_CONTROLLER_STATE_DIR:-/var/lib/terna-static-dr}"
failure_threshold="${TERNA_CONTROLLER_FAILURE_THRESHOLD:-3}"
interval_seconds="${TERNA_CONTROLLER_INTERVAL_SECONDS:-120}"
dns_node="${TERNA_LXC_DNS_NODE:-server-dns}"
k3s_node="${TERNA_LXC_K3S_NODE:-k3s-datacenter}"
namespace="${TERNA_LXC_STATIC_NAMESPACE:-terna-static-dr}"
zone="${TERNA_DNS_ZONE:-terna.it}"
target_ip="${TERNA_DNS_TARGET_IP:-10.10.3.10}"
ttl="${TERNA_DNS_TTL_SECONDS:-30}"
# Query router-edge rather than server-dns: it uses the WAN-provided resolver
# and remains outside the optional lab-only terna.it zone.
public_dns_resolver="${TERNA_PUBLIC_DNS_RESOLVER:-10.10.4.2}"
static_health_url="${TERNA_STATIC_HEALTH_URL:-http://terna.it/health}"
failover_playbook="${ROOT_DIR}/ansible/playbooks/terna-static-dr-failover.yml"
ansible_inventory="${ROOT_DIR}/ansible/inventory.ini"

is_positive_integer() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }
is_ipv4() {
  local IFS=. octets=()
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  read -r -a octets <<<"$1"
  [ "${#octets[@]}" -eq 4 ] || return 1
  local octet
  for octet in "${octets[@]}"; do
    [ "$((10#${octet}))" -le 255 ] || return 1
  done
}
state_file() { printf '%s/%s\n' "${state_dir}" "$1"; }
read_state() { [ -f "$(state_file "$1")" ] && cat "$(state_file "$1")" || printf '%s\n' "$2"; }
write_state() { mkdir -p "${state_dir}"; local tmp="$(state_file "$1").$$"; printf '%s\n' "$2" >"${tmp}"; chmod 0600 "${tmp}"; mv -f "${tmp}" "$(state_file "$1")"; }

validate() {
  [[ "${mode}" =~ ^(watch|oneshot|validate|delete-lab-zone)$ ]] || { echo 'Mode must be watch, oneshot, validate or delete-lab-zone.' >&2; return 1; }
  [ "$(hostname -s)" = "ansible-node" ] || { echo 'The Terna controller must run inside ansible-node.' >&2; return 1; }
  [ "${TERNA_DR_AUTO_FAILOVER_ENABLED:-false}" = true ] || { echo 'TERNA_DR_AUTO_FAILOVER_ENABLED must be true.' >&2; return 1; }
  is_positive_integer "${failure_threshold}" && is_positive_integer "${interval_seconds}" && is_positive_integer "${ttl}" || { echo 'Controller thresholds and DNS TTL must be positive integers.' >&2; return 1; }
  [[ "${TERNA_PRIMARY_PROBE_URL:-}" =~ ^https://www\.terna\.it(/|$) ]] || { echo 'TERNA_PRIMARY_PROBE_URL must be https://www.terna.it/...' >&2; return 1; }
  [[ "${static_health_url}" =~ ^http://(www\.)?terna\.it(/[A-Za-z0-9._~/%?=&-]*)?$ ]] || { echo 'TERNA_STATIC_HEALTH_URL must be an HTTP URL on terna.it or www.terna.it.' >&2; return 1; }
  is_ipv4 "${public_dns_resolver}" || { echo 'TERNA_PUBLIC_DNS_RESOLVER must be an IPv4 address.' >&2; return 1; }
  [ "${zone}" = terna.it ] || { echo 'Only the lab zone terna.it is supported by this PoC.' >&2; return 1; }
  is_ipv4 "${target_ip}" || { echo 'TERNA_DNS_TARGET_IP must be an IPv4 address.' >&2; return 1; }
  command -v lxc >/dev/null 2>&1
  command -v dig >/dev/null 2>&1
  command -v ansible-playbook >/dev/null 2>&1
  [ -r "${failover_playbook}" ] && [ -r "${ansible_inventory}" ] || { echo 'Terna failover Ansible playbook is missing.' >&2; return 1; }
  lxc list "${dns_node}" --format csv -c n | grep -qx "${dns_node}"
  lxc list "${k3s_node}" --format csv -c n | grep -qx "${k3s_node}"
}

public_terna_ip() {
  local candidate
  while IFS= read -r candidate; do
    if is_ipv4 "${candidate}"; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done < <(dig +short "@${public_dns_resolver}" www.terna.it A)
  echo 'The public DNS resolver returned no valid IPv4 address for www.terna.it.' >&2
  return 1
}

primary_ready() {
  local public_ip
  public_ip="$(public_terna_ip)" || return 1
  curl --fail --silent --show-error --connect-timeout 5 --max-time 15 \
    --resolve "www.terna.it:443:${public_ip}" "${TERNA_PRIMARY_PROBE_URL}" >/dev/null
}

static_ready() {
  local static_host
  static_host="${static_health_url#http://}"
  static_host="${static_host%%/*}"
  lxc exec "${k3s_node}" -- kubectl -n "${namespace}" rollout status deployment/terna-static-web --timeout=45s >/dev/null &&
    lxc exec "${k3s_node}" -- test -f /srv/terna-static-dr/static/current/index.html &&
    lxc exec "${k3s_node}" -- test -s /srv/terna-static-dr/static/current/manifest.json &&
    lxc exec "${k3s_node}" -- test -f /srv/terna-static-dr/static/current/.bundle-v1 &&
    lxc exec "${k3s_node}" -- test -s /srv/terna-static-dr/static/current/dr/load-chart/index.html &&
    lxc exec "${k3s_node}" -- test -s /srv/terna-static-dr/static/current/dr/load-chart/data.json &&
    lxc exec "${k3s_node}" -- sh -ec \
      'chart=/srv/terna-static-dr/static/current/dr/load-chart; test -f "${chart}/.load-chart-v1" || test -f "${chart}/.load-chart-placeholder-v1"' &&
    curl --fail --silent --show-error --connect-timeout 5 --max-time 15 \
      --resolve "${static_host}:80:${target_ip}" "${static_health_url}" >/dev/null
}

render_zone() {
  local serial
  serial="$(date +%s)"
  cat <<EOF
\$TTL ${ttl}
@ IN SOA server-dns.azienda.lan. admin.azienda.lan. (
  ${serial} 30 15 604800 ${ttl}
)
@ IN NS server-dns.azienda.lan.
@ IN A ${target_ip}
www IN A ${target_ip}
EOF
}

run_failover_playbook() {
  mkdir -p "${state_dir}"
  ansible-playbook -i "${ansible_inventory}" "${failover_playbook}" \
    --extra-vars "dns_node=${dns_node} k3s_node=${k3s_node} dns_target_ip=${target_ip} dns_ttl=${ttl} controller_state_dir=${state_dir}"
}

delete_lab_zone() {
  lxc exec "${dns_node}" -- bash -lc 'sed -i "/^zone \"terna.it\" {/,/^};$/d" /etc/bind/named.conf.local; rm -f /etc/bind/zones/db.terna.it; named-checkconf; systemctl reload named'
  lxc exec "${k3s_node}" -- rm -f /srv/terna-static-dr/static/dr-active
  write_state mode primary
  write_state failures 0
  echo 'Removed the lab-only terna.it zone; server-dns will recurse to public DNS again.'
}

evaluate_once() {
  local current failures
  current="$(read_state mode primary)"
  failures="$(read_state failures 0)"
  if primary_ready; then
    write_state failures 0
    echo "public Terna primary ready; lab DNS remains ${current} (cutback is manual)"
    return 0
  fi
  failures=$((failures + 1))
  write_state failures "${failures}"
  echo "public Terna primary unavailable (${failures}/${failure_threshold})"
  if [ "${current}" = primary ] && [ "${failures}" -ge "${failure_threshold}" ]; then
    static_ready || { echo 'Static DR pod is not ready; refusing lab DNS failover.' >&2; return 1; }
    if ! run_failover_playbook; then
      echo 'Ansible DNS failover failed; controller state remains primary.' >&2
      return 1
    fi
    write_state mode dr
    echo 'Lab DNS now resolves terna.it and www.terna.it to the static DR pod ingress.'
  fi
}

validate
case "${mode}" in
  validate) echo 'LXC-lab Terna static DR controller is valid and armed.' ;;
  delete-lab-zone) delete_lab_zone ;;
  oneshot) evaluate_once ;;
  watch) while true; do evaluate_once || true; sleep "${interval_seconds}"; done ;;
esac
