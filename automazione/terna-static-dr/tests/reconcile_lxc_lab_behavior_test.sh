#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temp_dir="$(mktemp -d)"
trap 'rm -rf -- "${temp_dir}"' EXIT

mkdir -p "${temp_dir}/bin"
export TERNA_TEST_LXC_LOG="${temp_dir}/lxc.log"
export TERNA_TEST_STATE_DIR="${temp_dir}/state"
mkdir -p "${TERNA_TEST_STATE_DIR}"

cat >"${temp_dir}/bin/lxc" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"${TERNA_TEST_LXC_LOG}"

if [ "${1:-}" = list ]; then
  instance="${2:-}"
  if test -f "${TERNA_TEST_STATE_DIR}/${instance}.running"; then
    printf '%s\n' RUNNING
  else
    printf '%s\n' STOPPED
  fi
  exit 0
fi

if [ "${1:-}" = start ]; then
  touch "${TERNA_TEST_STATE_DIR}/${2}.running"
  exit 0
fi

if [ "${1:-}" = exec ] && [ "${2:-}" = router-edge ] \
  && [[ " $* " == *' uci -q get '* ]]; then
  test "${TERNA_TEST_EDGE_READY:-true}" = true \
    || test -f "${TERNA_TEST_STATE_DIR}/edge-configured"
  exit
fi

if [ "${1:-}" = exec ] && [ "${2:-}" = router-edge ] \
  && [[ "$*" == *'set network.route_dc=route'* ]]; then
  touch "${TERNA_TEST_STATE_DIR}/edge-configured"
  exit 0
fi

if [ "${1:-}" = exec ] && [ "${2:-}" = k3s-datacenter ]; then
  shift 3
  if [ "${1:-}" = test ] && [ "${2:-}" = -f ] && [[ "${3:-}" == */dr-active ]]; then
    test "${TERNA_TEST_DR_ACTIVE:-false}" = true
    exit
  fi
  if [ "${1:-}" = dig ]; then
    attempts_file="${TERNA_TEST_STATE_DIR}/dns-attempts"
    attempts="$(cat "${attempts_file}" 2>/dev/null || printf 0)"
    attempts=$((attempts + 1))
    printf '%s\n' "${attempts}" >"${attempts_file}"
    if [ "${attempts}" -gt "${TERNA_TEST_DNS_FAILURES:-0}" ]; then
      printf '%s\n' "${TERNA_TEST_DNS_ANSWER:-151.101.2.132}"
    fi
    exit 0
  fi
fi

exit 0
EOF

cat >"${temp_dir}/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${temp_dir}/bin/lxc" "${temp_dir}/bin/sleep"

# The production script is sourced so the behavior can be verified without
# provisioning the real lab.
export TERNA_RECONCILE_SOURCE_ONLY=true
PATH="${temp_dir}/bin:${PATH}"
source "${ROOT_DIR}/bin/reconcile-lxc-lab.sh"

TERNA_TEST_DR_ACTIVE=false ensure_terna_runtime_instances
for instance in ansible-node k3s-datacenter router-edge router-dmz router-datacenter server-dns; do
  test -f "${TERNA_TEST_STATE_DIR}/${instance}.running"
  grep -F "config set ${instance} boot.autostart true" "${TERNA_TEST_LXC_LOG}" >/dev/null
done

: >"${TERNA_TEST_LXC_LOG}"
ensure_internal_router_runtime_configuration
grep -F 'exec router-datacenter -- ash -c' "${TERNA_TEST_LXC_LOG}" >/dev/null
grep -F 'ip address replace 10.10.3.1/24 dev eth0' "${TERNA_TEST_LXC_LOG}" >/dev/null
grep -F 'exec router-dmz -- ash -c' "${TERNA_TEST_LXC_LOG}" >/dev/null
grep -F 'nft flush ruleset' "${TERNA_TEST_LXC_LOG}" >/dev/null

: >"${TERNA_TEST_LXC_LOG}"
TERNA_TEST_EDGE_READY=false ensure_router_edge_runtime_configuration
grep -F 'set network.route_dc=route' "${TERNA_TEST_LXC_LOG}" >/dev/null
grep -F 'set dhcp.@dnsmasq[0].localservice=0' "${TERNA_TEST_LXC_LOG}" >/dev/null
grep -F 'net.ipv4.conf.all.rp_filter=2' "${TERNA_TEST_LXC_LOG}" >/dev/null

: >"${TERNA_TEST_LXC_LOG}"
rm -f "${TERNA_TEST_STATE_DIR}/dns-attempts"
TERNA_TEST_DNS_FAILURES=2 ensure_public_dns_path
grep -F 'exec router-edge -- ifup wan' "${TERNA_TEST_LXC_LOG}" >/dev/null
grep -F 'exec router-edge -- /etc/init.d/dnsmasq restart' "${TERNA_TEST_LXC_LOG}" >/dev/null
grep -F 'exec server-dns -- systemctl restart named' "${TERNA_TEST_LXC_LOG}" >/dev/null

: >"${TERNA_TEST_LXC_LOG}"
rm -f "${TERNA_TEST_STATE_DIR}/dns-attempts"
set +e
TERNA_TEST_DNS_FAILURES=0 TERNA_TEST_DNS_ANSWER=10.10.4.2 ensure_public_dns_path
private_status=$?
set -e
test "${private_status}" -ne 0

: >"${TERNA_TEST_LXC_LOG}"
rm -f "${TERNA_TEST_STATE_DIR}/dns-attempts"
set +e
TERNA_TEST_DR_ACTIVE=true TERNA_TEST_DNS_FAILURES=99 ensure_public_dns_path
dr_status=$?
set -e
test "${dr_status}" -ne 0
if grep -Fq 'ifup wan' "${TERNA_TEST_LXC_LOG}"; then
  echo 'WAN recovery must not run while DR is active.' >&2
  exit 1
fi

# Chrome is optional for availability: without public DNS the reconcile must
# not enter APT and must leave the existing static bundle untouched.
lxc() {
  printf '%s\n' "$*" >>"${TERNA_TEST_LXC_LOG}"
  if [[ " $* " == *' google-chrome --version '* ]]; then
    return 1
  fi
  if [[ " $* " == *' apt-get '* ]]; then
    return 99
  fi
  return 0
}
export -f lxc
: >"${TERNA_TEST_LXC_LOG}"
PUBLIC_DNS_PATH_READY=false ensure_chart_browser
if grep -Fq 'apt-get' "${TERNA_TEST_LXC_LOG}"; then
  echo 'Chrome installation must be skipped while public DNS is unavailable.' >&2
  exit 1
fi
unset -f lxc

# A failed origin refresh must not invalidate a previously published bundle.
# This mock makes every bundle marker valid while forcing only the service
# start to fail.
lxc() {
  printf '%s\n' "$*" >>"${TERNA_TEST_LXC_LOG}"
  if [[ " $* " == *' cat /var/lib/terna-static-dr/origin-fetcher-checksum '* ]]; then
    printf '%s\n' old-checksum
  elif [[ " $* " == *' test -f /srv/terna-static-dr/static/dr-active '* ]]; then
    return 1
  elif [[ " $* " == *' systemctl start terna-static-origin-fetch.service '* ]]; then
    return 42
  fi
  return 0
}
sha256sum() {
  printf '%s  %s\n' desired-checksum -
}
export -f lxc sha256sum
ensure_origin_fetcher
unset -f lxc sha256sum

echo 'LXC reconcile behavior test passed.'
