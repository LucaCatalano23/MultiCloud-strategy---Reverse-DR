#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "${ROOT_DIR}/../.." && pwd)"

require_text() { grep -Fq -- "$2" "$1" || { echo "Missing '$2' in $1" >&2; exit 1; }; }
require_file() { test -f "$1" || { echo "Missing $1" >&2; exit 1; }; }

require_file "${REPO_ROOT}/automazione/terna-static-dr/bin/reconcile-lxc-lab.sh"
require_file "${REPO_ROOT}/automazione/terna-static-dr/ansible/playbooks/terna-static-dr-failover.yml"
require_text "${ROOT_DIR}/setup.sh" 'reconcile-lxc-lab.sh'
require_text "${ROOT_DIR}/setup.sh" 'snap install lxd --channel=5.21/stable'
require_text "${ROOT_DIR}/setup.sh" 'forwarders { 10.10.4.2; };'
require_text "${ROOT_DIR}/setup.sh" '/etc/bind/named.conf.d/lxc-lab.conf'
require_text "${ROOT_DIR}/setup.sh" '/^zone "lab\.lxc" {/,/^};$/d'
if grep -Fq 'cat >/etc/bind/named.conf.local' "${ROOT_DIR}/setup.sh"; then
  echo 'setup must preserve application zones already registered in named.conf.local.' >&2
  exit 1
fi
require_text "${ROOT_DIR}/setup.sh" 'add_list dhcp.@dnsmasq[0].interface=transit'
require_text "${ROOT_DIR}/setup.sh" 'set dhcp.@dnsmasq[0].localservice=0'
require_text "${ROOT_DIR}/setup.sh" 'uci -q delete dhcp.@dnsmasq[0].interface || true'
require_text "${ROOT_DIR}/setup.sh" 'uci -q delete dhcp.@dnsmasq[0].listen_address || true'
require_text "${ROOT_DIR}/setup.sh" 'uci add_list dhcp.@dnsmasq[0].listen_address=127.0.0.1'
require_text "${ROOT_DIR}/setup.sh" 'uci add_list dhcp.@dnsmasq[0].listen_address=10.10.4.2'
require_text "${ROOT_DIR}/setup.sh" 'uci set dhcp.@dnsmasq[0].nonwildcard=1'
require_text "${ROOT_DIR}/setup.sh" 'net.ipv4.conf.all.rp_filter=2'
require_text "${ROOT_DIR}/setup.sh" '/etc/sysctl.d/99-lxc-lab-edge.conf'
require_text "${ROOT_DIR}/setup.sh" 'verify_wan_dns_path'
require_text "${ROOT_DIR}/setup.sh" 'exec "${container}" -- ash -c'
if grep -Fq '/etc/init.d/network restart' "${ROOT_DIR}/setup.sh"; then
  echo 'OpenWrt network restart is not safe in LXC: runtime networking must be applied without a blocking ubus restart.' >&2
  exit 1
fi
require_text "${ROOT_DIR}/setup.sh" 'ip address replace 10.10.3.1/24 dev eth0'
require_text "${ROOT_DIR}/setup.sh" 'ip route replace default via 10.10.2.4 dev eth1'
require_text "${ROOT_DIR}/setup.sh" 'ip address replace 10.10.4.1/24 dev eth1'
require_text "${ROOT_DIR}/setup.sh" 'ip address replace 10.10.4.2/24 dev eth0'
require_text "${ROOT_DIR}/setup.sh" 'nft flush ruleset'
require_text "${ROOT_DIR}/setup.sh" 'net.ipv4.conf.all.rp_filter=0'
require_text "${ROOT_DIR}/setup.sh" 'net.ipv4.icmp_echo_ignore_all=0'
require_text "${ROOT_DIR}/setup.sh" 'dig @10.10.4.2 +time=2 +tries=1 +short registry-1.docker.io A'
require_text "${ROOT_DIR}/setup.sh" 'lxc exec router-dmz -- nslookup registry-1.docker.io 10.10.4.2'
require_text "${ROOT_DIR}/setup.sh" 'lxc exec router-edge -- busybox netstat -lnup'
require_text "${ROOT_DIR}/setup.sh" 'dig @10.10.2.53 +time=4 +tries=1 +short registry-1.docker.io A'
require_text "${ROOT_DIR}/setup.sh" 'set network.route_dc.gateway=10.10.4.1'
require_text "${ROOT_DIR}/setup.sh" 'set network.route_dmz.gateway=10.10.4.1'
require_text "${ROOT_DIR}/setup.sh" 'set network.route_dipendenti.gateway=10.10.4.1'
require_text "${ROOT_DIR}/setup.sh" 'config device get "${container}" "${device}" network'
require_text "${ROOT_DIR}/setup.sh" 'if [ "${current_network}" != "${network}" ]; then'
require_text "${ROOT_DIR}/setup.sh" 'attach_nic router-edge lxdbr0 eth1'
if grep -Fq 'forwarders { 1.1.1.1; 8.8.8.8; };' "${ROOT_DIR}/setup.sh"; then
  echo 'server-dns must use the WAN resolver exposed by router-edge, not public DNS servers directly.' >&2
  exit 1
fi
if grep -Fq 'apt_install ansible-node ansible-core git openssh-client dnsutils curl ca-certificates lxd-client' "${ROOT_DIR}/setup.sh"; then
  echo 'Ubuntu 24.04 does not provide the lxd-client APT package.' >&2
  exit 1
fi
require_text "${REPO_ROOT}/automazione/terna-static-dr/bin/reconcile-lxc-lab.sh" 'kubectl apply -k'
require_text "${REPO_ROOT}/automazione/terna-static-dr/bin/reconcile-lxc-lab.sh" 'ensure_internal_router_runtime_configuration'
if grep -Fq '/etc/init.d/network restart' "${REPO_ROOT}/automazione/terna-static-dr/bin/reconcile-lxc-lab.sh"; then
  echo 'Terna reconcile must not use the blocking OpenWrt network restart path.' >&2
  exit 1
fi
require_text "${REPO_ROOT}/automazione/terna-static-dr/bin/reconcile-lxc-lab.sh" 'TERNA_DR_ALLOW_REFRESH_DURING_DR=true'
require_text "${REPO_ROOT}/automazione/terna-static-dr/bin/reconcile-lxc-lab.sh" 'provision-checksum'
require_text "${REPO_ROOT}/automazione/terna-static-dr/bin/reconcile-lxc-lab.sh" 'source-config-checksum'
require_text "${REPO_ROOT}/automazione/terna-static-dr/bin/reconcile-lxc-lab.sh" "--exclude='./config.lxc-lab.env'"
require_text "${REPO_ROOT}/automazione/terna-static-dr/bin/reconcile-lxc-lab.sh" 'lxd-socket'
require_text "${REPO_ROOT}/automazione/terna-static-dr/bin/reconcile-lxc-lab.sh" 'config device remove'
require_text "${REPO_ROOT}/automazione/terna-static-dr/bin/reconcile-lxc-lab.sh" 'snap install lxd --channel=5.21/stable'
require_text "${REPO_ROOT}/automazione/terna-static-dr/bin/reconcile-lxc-lab.sh" 'https://get.k3s.io'
require_text "${REPO_ROOT}/automazione/terna-static-dr/bin/reconcile-lxc-lab.sh" 'kubectl get nodes'
require_text "${REPO_ROOT}/automazione/terna-static-dr/bin/lxc-lab-controller.sh" 'ansible-playbook'
require_text "${REPO_ROOT}/automazione/terna-static-dr/ansible/playbooks/terna-static-dr-failover.yml" 'server-dns'
require_text "${REPO_ROOT}/automazione/terna-static-dr/ansible/playbooks/terna-static-dr-failover.yml" 'k3s-datacenter'

echo 'LXC setup Terna static DR contract passed.'
