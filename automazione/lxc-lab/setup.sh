#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=topology.env
source "${SCRIPT_DIR}/topology.env"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

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

require_lxd() {
  require_command lxc
  if ! lxc_retry info >/dev/null 2>&1; then
    cat >&2 <<'EOF'
LXD is not available for the current user.
On Ubuntu WSL run:
  sudo snap install lxd
  sudo lxd init --minimal
  sudo usermod -aG lxd "$USER"
  newgrp lxd
EOF
    exit 1
  fi
}

image_exists() {
  local image="$1"
  lxc_retry image info "${image}" >/dev/null 2>&1
}

resolve_openwrt_image() {
  local candidates=(
    "${OPENWRT_IMAGE}"
    "images:openwrt/23.05/amd64"
    "images:openwrt/23.05"
    "images:openwrt/22.03/amd64"
    "images:openwrt/22.03"
  )

  for image in "${candidates[@]}"; do
    if image_exists "${image}"; then
      printf '%s\n' "${image}"
      return 0
    fi
  done

  cat >&2 <<EOF
No usable OpenWrt LXD image was found.

Tried:
$(printf '  - %s\n' "${candidates[@]}")

Check available aliases with:
  lxc image list images: openwrt

Then rerun setup with the exact alias, for example:
  OPENWRT_IMAGE='images:<alias>' bash setup.sh
EOF
  return 1
}

preflight() {
  echo "Checking required LXD images..."

  if ! image_exists "${UBUNTU_IMAGE}"; then
    cat >&2 <<EOF
Ubuntu image is not available: ${UBUNTU_IMAGE}
Check it with:
  lxc image info ${UBUNTU_IMAGE}
EOF
    exit 1
  fi

  RESOLVED_OPENWRT_IMAGE="$(resolve_openwrt_image)"
  export RESOLVED_OPENWRT_IMAGE
  echo "Using Ubuntu image: ${UBUNTU_IMAGE}"
  echo "Using OpenWrt image: ${RESOLVED_OPENWRT_IMAGE}"
}

create_network() {
  local name="$1"
  local cidr="$2"
  local gateway="$3"

  if ! lxc_retry network show "${name}" >/dev/null 2>&1; then
    lxc_retry network create "${name}" \
      ipv4.address="${cidr}" \
      ipv4.nat=false \
      ipv4.dhcp=true \
      ipv4.dhcp.gateway="${gateway}" \
      ipv6.address=none
  else
    lxc_retry network set "${name}" ipv4.address "${cidr}"
    lxc_retry network set "${name}" ipv4.nat false
    lxc_retry network set "${name}" ipv4.dhcp true
    lxc_retry network set "${name}" ipv4.dhcp.gateway "${gateway}"
    lxc_retry network set "${name}" ipv6.address none
  fi
}

init_container() {
  local name="$1"
  local image="$2"

  if ! lxc_retry info "${name}" >/dev/null 2>&1; then
    lxc_retry init "${image}" "${name}"
    if lxc_retry config device show "${name}" | grep -q '^eth0:'; then
      lxc_retry config device remove "${name}" eth0
    fi
  fi
}

configure_container_runtime() {
  local name="$1"
  local kind="$2"
  local autostart="${3:-false}"

  lxc_retry config set "${name}" boot.autostart "${autostart}"
  lxc_retry config set "${name}" security.nesting true

  if [ "${kind}" = "openwrt-router" ] || [ "${kind}" = "k3s-node" ]; then
    # OpenWrt init scripts touch low-level networking paths that are unreliable
    # in strict unprivileged containers, especially inside WSL-backed LXD.
    if ! lxc_retry info "${name}" | grep -q 'Status: Running'; then
      lxc_retry config set "${name}" security.privileged true
    fi
  fi
}

attach_provisioning_nic() {
  local container="$1"

  if lxc_retry network show lxdbr0 >/dev/null 2>&1; then
    if ! lxc_retry config device show "${container}" | grep -q '^eth9:'; then
      lxc_retry network attach lxdbr0 "${container}" eth9 eth9
    fi
  else
    cat >&2 <<'EOF'
Missing LXD default network lxdbr0.
Ubuntu nodes need a temporary provisioning NIC on lxdbr0 to install packages
before returning to the isolated lab topology.
EOF
    exit 1
  fi
}

remove_provisioning_nic() {
  local container="$1"

  if lxc_retry info "${container}" | grep -q 'Status: Running'; then
    lxc_retry exec "${container}" -- bash -lc '
      rm -f /etc/netplan/99-lxc-provisioning.yaml
      netplan apply >/dev/null 2>&1 || true
    ' || true
  fi

  if lxc_retry config device show "${container}" | grep -q '^eth9:'; then
    lxc_retry config device remove "${container}" eth9
  fi
}

attach_nic() {
  local container="$1"
  local network="$2"
  local device="$3"
  local address="$4"

  if ! lxc_retry config device show "${container}" | grep -q "^${device}:"; then
    lxc_retry network attach "${network}" "${container}" "${device}" "${device}"
  fi
  lxc_retry config device set "${container}" "${device}" ipv4.address "${address}"
}

ensure_started() {
  local container="$1"
  if ! lxc_retry info "${container}" | grep -q 'Status: Running'; then
    if ! lxc_retry start "${container}"; then
      echo "Failed to start ${container}. LXD state follows:" >&2
      lxc_retry info "${container}" --show-log >&2 || true
      exit 1
    fi
  fi
}

wait_for_cloud_init() {
  local container="$1"
  lxc_retry exec "${container}" -- cloud-init status --wait >/dev/null
}

wait_for_apt() {
  local container="$1"
  lxc_retry exec "${container}" -- bash -lc '
    for _ in $(seq 1 120); do
      fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
      fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || \
      fuser /var/cache/apt/archives/lock >/dev/null 2>&1 || exit 0
      sleep 1
    done
    exit 1
  '
}

configure_apt_ipv4() {
  local container="$1"
  lxc_retry exec "${container}" -- bash -lc \
    "printf 'Acquire::ForceIPv4 \"true\";\n' >/etc/apt/apt.conf.d/99force-ipv4"
}

enable_ubuntu_universe() {
  local container="$1"
  lxc_retry exec "${container}" -- bash -lc '
    set -euo pipefail
    if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
      sed -i -E "/^Components:/ {
        /(^| )universe( |$)/! s/$/ universe/
      }" /etc/apt/sources.list.d/ubuntu.sources
    elif [ -f /etc/apt/sources.list ]; then
      sed -i -E "s/ main([[:space:]]|$)/ main universe\\1/g" /etc/apt/sources.list
    fi
  '
}

use_provisioning_route() {
  local container="$1"
  local gateway

  gateway="$(lxc_retry network get lxdbr0 ipv4.address | cut -d/ -f1)"
  if [ -z "${gateway}" ] || [ "${gateway}" = "none" ]; then
    echo "lxdbr0 has no IPv4 gateway address" >&2
    lxc_retry network show lxdbr0 >&2 || true
    exit 1
  fi

  lxc_retry exec "${container}" -- bash -lc '
    set -euo pipefail
    if command -v netplan >/dev/null 2>&1; then
      cat >/etc/netplan/99-lxc-provisioning.yaml <<EOF
network:
  version: 2
  ethernets:
    eth9:
      dhcp4: true
      dhcp6: false
EOF
      netplan apply >/dev/null 2>&1 || true
    fi

    systemctl restart systemd-networkd >/dev/null 2>&1 || true
    networkctl reconfigure eth9 >/dev/null 2>&1 || true

    for _ in $(seq 1 90); do
      ip -4 addr show dev eth9 | grep -q "inet " && break
      sleep 1
    done

    if ! ip -4 addr show dev eth9 | grep -q "inet "; then
      echo "eth9 has no IPv4 address for provisioning" >&2
      ip addr show dev eth9 >&2 || true
      ip route >&2 || true
      exit 1
    fi

    ip route replace default via "$1" dev eth9
  ' -- "${gateway}"
}

use_lab_route() {
  local container="$1"
  local gateway="$2"
  lxc_retry exec "${container}" -- ip route replace default via "${gateway}" dev eth0
}

apt_install() {
  local container="$1"
  shift
  configure_apt_ipv4 "${container}"
  enable_ubuntu_universe "${container}"
  use_provisioning_route "${container}"
  wait_for_apt "${container}"
  lxc_retry exec "${container}" -- env DEBIAN_FRONTEND=noninteractive apt-get update
  lxc_retry exec "${container}" -- env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

configure_ubuntu_host() {
  local container="$1"
  lxc_retry exec "${container}" -- bash -lc "
    install -d /etc/systemd/resolved.conf.d
    cat >/etc/systemd/resolved.conf.d/lxc-lab.conf <<EOF
[Resolve]
DNS=${DNS_IP}
Domains=${LAB_DOMAIN}
EOF
    systemctl restart systemd-resolved || true
  "
}

configure_git_server() {
  wait_for_cloud_init git-server
  apt_install git-server git git-daemon-sysvinit openssh-server ca-certificates
  configure_ubuntu_host git-server
  use_lab_route git-server 10.10.3.1

  lxc_retry exec git-server -- bash -lc '
    set -euo pipefail
    install -d -o gitdaemon -g nogroup /srv/git
    if [ ! -d /srv/git/infrastructure.git ]; then
      git init --bare /srv/git/infrastructure.git
      tmp="$(mktemp -d)"
      git -C "$tmp" init
      git -C "$tmp" config user.name "LXC Lab"
      git -C "$tmp" config user.email "lab@example.invalid"
      printf "# Infrastructure Repository\n\nSeed repository for the LXC lab.\n" >"$tmp/README.md"
      git -C "$tmp" add README.md
      git -C "$tmp" commit -m "Initial infrastructure repository"
      git -C "$tmp" branch -M main
      git -C "$tmp" remote add origin /srv/git/infrastructure.git
      git -C "$tmp" push origin main
      rm -rf "$tmp"
    fi
    chown -R gitdaemon:nogroup /srv/git
    sed -i "s|^GIT_DAEMON_ENABLE=.*|GIT_DAEMON_ENABLE=true|" /etc/default/git-daemon
    sed -i "s|^GIT_DAEMON_DIRECTORY=.*|GIT_DAEMON_DIRECTORY=/srv/git|" /etc/default/git-daemon
    sed -i "s|^GIT_DAEMON_OPTIONS=.*|GIT_DAEMON_OPTIONS=\"--export-all --base-path=/srv/git /srv/git\"|" /etc/default/git-daemon
    systemctl enable --now ssh git-daemon
    systemctl restart git-daemon
  '
}

configure_dns_server() {
  wait_for_cloud_init server-dns
  apt_install server-dns bind9 bind9-dnsutils
  use_lab_route server-dns 10.10.2.4

  lxc_retry exec server-dns -- bash -lc "cat >/etc/bind/named.conf.options" <<'EOF'
options {
  directory "/var/cache/bind";
  listen-on { any; };
  allow-query { any; };
  recursion yes;
  dnssec-validation auto;
  forwarders { 1.1.1.1; 8.8.8.8; };
};
EOF

  lxc_retry exec server-dns -- bash -lc "cat >/etc/bind/named.conf.local" <<EOF
zone "${LAB_DOMAIN}" {
  type master;
  file "/etc/bind/db.${LAB_DOMAIN}";
};
EOF

  lxc_retry exec server-dns -- bash -lc "cat >/etc/bind/db.${LAB_DOMAIN}" <<EOF
\$TTL 300
@ IN SOA server-dns.${LAB_DOMAIN}. admin.${LAB_DOMAIN}. (
  2026070801 300 120 604800 300
)
@ IN NS server-dns.${LAB_DOMAIN}.
server-dns IN A 10.10.2.53
router-dipendenti IN A 10.10.1.1
router-datacenter IN A 10.10.3.1
router-dmz IN A 10.10.4.1
router-edge IN A 10.10.4.2
pc-dipendente1 IN A 10.10.1.193
k3s-datacenter IN A 10.10.3.10
proxy-keycloak IN A 10.10.3.50
egress-proxy IN A 10.10.3.60
git-server IN A 10.10.3.70
ansible-node IN A 10.10.3.100
EOF

  lxc_retry exec server-dns -- named-checkconf
  lxc_retry exec server-dns -- named-checkzone "${LAB_DOMAIN}" "/etc/bind/db.${LAB_DOMAIN}"
  lxc_retry exec server-dns -- systemctl enable --now named
  lxc_retry exec server-dns -- systemctl restart named
}

configure_ansible_node() {
  wait_for_cloud_init ansible-node
  apt_install ansible-node ansible-core git openssh-client dnsutils curl ca-certificates
  configure_ubuntu_host ansible-node
  use_lab_route ansible-node 10.10.3.1

  lxc_retry exec ansible-node -- install -d /etc/ansible
  lxc_retry exec ansible-node -- bash -lc "cat >/etc/ansible/hosts" <<EOF
[datacenter]
k3s-datacenter ansible_host=10.10.3.10
proxy-keycloak ansible_host=10.10.3.50
egress-proxy ansible_host=10.10.3.60
git-server ansible_host=10.10.3.70

[network]
router-dipendenti ansible_host=10.10.1.1
router-datacenter ansible_host=10.10.3.1
router-dmz ansible_host=10.10.4.1
router-edge ansible_host=10.10.4.2

[dns]
server-dns ansible_host=10.10.2.53
EOF
}

configure_basic_ubuntu_nodes() {
  local nodes=(
    "k3s-datacenter 10.10.3.1"
    "proxy-keycloak 10.10.3.1"
    "egress-proxy 10.10.3.1"
    "pc-dipendente1 10.10.1.1"
  )
  local entry node gateway
  for entry in "${nodes[@]}"; do
    node="${entry%% *}"
    gateway="${entry##* }"
    wait_for_cloud_init "${node}"
    apt_install "${node}" iproute2 iputils-ping dnsutils curl ca-certificates
    configure_ubuntu_host "${node}"
    use_lab_route "${node}" "${gateway}"
  done
}

remove_all_provisioning_nics() {
  local nodes=(ansible-node egress-proxy git-server k3s-datacenter pc-dipendente1 proxy-keycloak server-dns)
  local node
  for node in "${nodes[@]}"; do
    remove_provisioning_nic "${node}"
  done
}

openwrt_exec() {
  local container="$1"
  shift
  lxc_retry exec "${container}" -- ash -lc "$*"
}

configure_openwrt_firewall() {
  local container="$1"
  openwrt_exec "${container}" '
    set -e
    /etc/init.d/firewall stop >/dev/null 2>&1 || true
    /etc/init.d/firewall disable >/dev/null 2>&1 || true
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
  '
}

reset_openwrt_network_defaults() {
  local container="$1"
  openwrt_exec "${container}" '
    set -e
    uci -q delete network.lan || true
    uci -q delete network.wan || true
    uci -q delete network.wan6 || true
    uci -q delete network.globals || true
    uci -q delete network.@device[0] || true
    uci -q delete network.@device[0] || true
    ip addr flush dev eth0 >/dev/null 2>&1 || true
    ip addr flush dev eth1 >/dev/null 2>&1 || true
    ip link set eth0 up >/dev/null 2>&1 || true
    ip link set eth1 up >/dev/null 2>&1 || true
  '
}

configure_router_dipendenti() {
  reset_openwrt_network_defaults router-dipendenti
  openwrt_exec router-dipendenti '
    set -e
    uci -q delete network.route_dc || true
    uci -q delete network.route_transit || true
    uci -q delete network.default_dmz || true
    uci batch <<EOF
set network.lan=interface
set network.lan.device=eth0
set network.lan.proto=static
set network.lan.ipaddr=10.10.1.1
set network.lan.netmask=255.255.255.0
set network.dmz=interface
set network.dmz.device=eth1
set network.dmz.proto=static
set network.dmz.ipaddr=10.10.2.2
set network.dmz.netmask=255.255.255.0
set network.route_dc=route
set network.route_dc.interface=dmz
set network.route_dc.target=10.10.3.0
set network.route_dc.netmask=255.255.255.0
set network.route_dc.gateway=10.10.2.3
set network.default_dmz=route
set network.default_dmz.interface=dmz
set network.default_dmz.target=0.0.0.0
set network.default_dmz.netmask=0.0.0.0
set network.default_dmz.gateway=10.10.2.4
commit network
EOF
    /etc/init.d/network restart
  '
  configure_openwrt_firewall router-dipendenti
}

configure_router_datacenter() {
  reset_openwrt_network_defaults router-datacenter
  openwrt_exec router-datacenter '
    set -e
    uci -q delete network.route_dipendenti || true
    uci -q delete network.route_transit || true
    uci -q delete network.default_dmz || true
    uci batch <<EOF
set network.lan=interface
set network.lan.device=eth0
set network.lan.proto=static
set network.lan.ipaddr=10.10.3.1
set network.lan.netmask=255.255.255.0
set network.dmz=interface
set network.dmz.device=eth1
set network.dmz.proto=static
set network.dmz.ipaddr=10.10.2.3
set network.dmz.netmask=255.255.255.0
set network.route_dipendenti=route
set network.route_dipendenti.interface=dmz
set network.route_dipendenti.target=10.10.1.0
set network.route_dipendenti.netmask=255.255.255.0
set network.route_dipendenti.gateway=10.10.2.2
set network.default_dmz=route
set network.default_dmz.interface=dmz
set network.default_dmz.target=0.0.0.0
set network.default_dmz.netmask=0.0.0.0
set network.default_dmz.gateway=10.10.2.4
commit network
EOF
    /etc/init.d/network restart
  '
  configure_openwrt_firewall router-datacenter
}

configure_router_dmz() {
  reset_openwrt_network_defaults router-dmz
  openwrt_exec router-dmz '
    set -e
    uci -q delete network.route_dipendenti || true
    uci -q delete network.route_dc || true
    uci -q delete network.default_edge || true
    uci batch <<EOF
set network.dmz=interface
set network.dmz.device=eth0
set network.dmz.proto=static
set network.dmz.ipaddr=10.10.2.4
set network.dmz.netmask=255.255.255.0
set network.transit=interface
set network.transit.device=eth1
set network.transit.proto=static
set network.transit.ipaddr=10.10.4.1
set network.transit.netmask=255.255.255.0
set network.route_dipendenti=route
set network.route_dipendenti.interface=dmz
set network.route_dipendenti.target=10.10.1.0
set network.route_dipendenti.netmask=255.255.255.0
set network.route_dipendenti.gateway=10.10.2.2
set network.route_dc=route
set network.route_dc.interface=dmz
set network.route_dc.target=10.10.3.0
set network.route_dc.netmask=255.255.255.0
set network.route_dc.gateway=10.10.2.3
set network.default_edge=route
set network.default_edge.interface=transit
set network.default_edge.target=0.0.0.0
set network.default_edge.netmask=0.0.0.0
set network.default_edge.gateway=10.10.4.2
commit network
EOF
    /etc/init.d/network restart
  '
  configure_openwrt_firewall router-dmz
}

configure_router_edge() {
  reset_openwrt_network_defaults router-edge
  openwrt_exec router-edge '
    set -e
    uci batch <<EOF
set network.transit=interface
set network.transit.device=eth0
set network.transit.proto=static
set network.transit.ipaddr=10.10.4.2
set network.transit.netmask=255.255.255.0
set network.wan=interface
set network.wan.device=eth1
set network.wan.proto=dhcp
commit network
EOF
    /etc/init.d/network restart

    cat >/etc/config/firewall <<EOF
config defaults
        option input REJECT
        option output ACCEPT
        option forward REJECT
        option synflood_protect 1

config zone
        option name transit
        list network transit
        option input ACCEPT
        option output ACCEPT
        option forward REJECT

config zone
        option name wan
        list network wan
        option input REJECT
        option output ACCEPT
        option forward REJECT
        option masq 1
        option mtu_fix 1

config forwarding
        option src transit
        option dest wan
EOF
    /etc/init.d/firewall enable >/dev/null 2>&1 || true
    /etc/init.d/firewall restart
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
  '
}

main() {
  require_lxd
  preflight

  create_network "${NET_DIPENDENTI}" "10.10.1.254/24" "10.10.1.1"
  create_network "${NET_DMZ}" "10.10.2.254/24" "10.10.2.4"
  create_network "${NET_DATACENTER}" "10.10.3.254/24" "10.10.3.1"
  create_network "${NET_TRANSIT}" "10.10.4.254/24" "10.10.4.2"

  init_container ansible-node "${UBUNTU_IMAGE}"
  # The DR coordinator must survive LXD/WSL restarts independently from the
  # simulated cloud failure domain.
  configure_container_runtime ansible-node ubuntu-service true
  attach_nic ansible-node "${NET_DATACENTER}" eth0 10.10.3.100
  attach_provisioning_nic ansible-node

  init_container egress-proxy "${UBUNTU_IMAGE}"
  configure_container_runtime egress-proxy ubuntu-service
  attach_nic egress-proxy "${NET_DATACENTER}" eth0 10.10.3.60
  attach_provisioning_nic egress-proxy

  init_container git-server "${UBUNTU_IMAGE}"
  configure_container_runtime git-server ubuntu-service
  attach_nic git-server "${NET_DATACENTER}" eth0 10.10.3.70
  attach_provisioning_nic git-server

  init_container k3s-datacenter "${UBUNTU_IMAGE}"
  configure_container_runtime k3s-datacenter k3s-node
  attach_nic k3s-datacenter "${NET_DATACENTER}" eth0 10.10.3.10
  attach_provisioning_nic k3s-datacenter

  init_container pc-dipendente1 "${UBUNTU_IMAGE}"
  configure_container_runtime pc-dipendente1 ubuntu-service
  attach_nic pc-dipendente1 "${NET_DIPENDENTI}" eth0 10.10.1.193
  attach_provisioning_nic pc-dipendente1

  init_container proxy-keycloak "${UBUNTU_IMAGE}"
  configure_container_runtime proxy-keycloak ubuntu-service
  attach_nic proxy-keycloak "${NET_DATACENTER}" eth0 10.10.3.50
  attach_provisioning_nic proxy-keycloak

  init_container server-dns "${UBUNTU_IMAGE}"
  configure_container_runtime server-dns ubuntu-service
  attach_nic server-dns "${NET_DMZ}" eth0 10.10.2.53
  attach_provisioning_nic server-dns

  init_container router-dipendenti "${RESOLVED_OPENWRT_IMAGE}"
  configure_container_runtime router-dipendenti openwrt-router
  attach_nic router-dipendenti "${NET_DIPENDENTI}" eth0 10.10.1.1
  attach_nic router-dipendenti "${NET_DMZ}" eth1 10.10.2.2

  init_container router-datacenter "${RESOLVED_OPENWRT_IMAGE}"
  configure_container_runtime router-datacenter openwrt-router
  attach_nic router-datacenter "${NET_DATACENTER}" eth0 10.10.3.1
  attach_nic router-datacenter "${NET_DMZ}" eth1 10.10.2.3

  init_container router-dmz "${RESOLVED_OPENWRT_IMAGE}"
  configure_container_runtime router-dmz openwrt-router
  attach_nic router-dmz "${NET_DMZ}" eth0 10.10.2.4
  attach_nic router-dmz "${NET_TRANSIT}" eth1 10.10.4.1

  init_container router-edge "${RESOLVED_OPENWRT_IMAGE}"
  configure_container_runtime router-edge openwrt-router
  attach_nic router-edge "${NET_TRANSIT}" eth0 10.10.4.2
  if ! lxc_retry config device show router-edge | grep -q '^eth1:'; then
    lxc_retry network attach lxdbr0 router-edge eth1 eth1
  fi

  for container in \
    router-dipendenti router-datacenter router-dmz router-edge \
    ansible-node egress-proxy git-server k3s-datacenter pc-dipendente1 proxy-keycloak server-dns; do
    ensure_started "${container}"
  done

  sleep 8
  configure_router_dipendenti
  configure_router_datacenter
  configure_router_dmz
  configure_router_edge
  configure_dns_server
  configure_git_server
  configure_ansible_node
  configure_basic_ubuntu_nodes
  remove_all_provisioning_nics

  lxc_retry list
  echo "LXC lab ready."
}

main "$@"
