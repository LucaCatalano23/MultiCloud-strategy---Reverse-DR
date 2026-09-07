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

# Machine-readable state avoids locale/case changes in `lxc info` (for example
# `RUNNING` rather than `Running`) that previously caused a duplicate start.
instance_running() {
  [ "$(lxc_retry list "$1" -c s --format csv 2>/dev/null | tr '[:lower:]' '[:upper:]' | tr -d '\r\n')" = "RUNNING" ]
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
    if ! instance_running "${name}"; then
      lxc_retry config set "${name}" security.privileged true
    fi
  fi
}

attach_provisioning_nic() {
  local container="$1"

  if lxc_retry network show lxdbr0 >/dev/null 2>&1; then
    attach_nic "${container}" lxdbr0 eth9
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

  if instance_running "${container}"; then
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
  local address="${4:-}"
  local current_network=""

  if lxc_retry config device show "${container}" | grep -q "^${device}:"; then
    current_network="$(lxc_retry config device get "${container}" "${device}" network 2>/dev/null || true)"
    if [ "${current_network}" != "${network}" ]; then
      echo "Realigning ${container}/${device}: ${current_network:-unknown} -> ${network}."
      lxc_retry config device remove "${container}" "${device}"
    fi
  fi

  if ! lxc_retry config device show "${container}" | grep -q "^${device}:"; then
    lxc_retry network attach "${network}" "${container}" "${device}" "${device}"
  fi
  if [ -n "${address}" ]; then
    lxc_retry config device set "${container}" "${device}" ipv4.address "${address}"
  fi
}

ensure_started() {
  local container="$1"
  if ! instance_running "${container}"; then
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
    # The lab networks are IPv4-only.  Disabling IPv6 prevents containerd from
    # stalling on unreachable AAAA records when it pulls images from registries.
    cat >/etc/sysctl.d/99-lxc-lab-ipv4-only.conf <<EOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
    sysctl --system >/dev/null || true
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
  include "/etc/bind/named.conf.d/helios-rpz-options.conf";
  // router-edge forwards through the resolver learned on its WAN DHCP lease.
  // This keeps recursion working on networks that block direct public DNS.
  forwarders { 10.10.4.2; };
};
EOF

  lxc_retry exec server-dns -- install -d -m 0755 /etc/bind/named.conf.d
  lxc_retry exec server-dns -- bash -lc "cat >/etc/bind/named.conf.d/lxc-lab.conf" <<EOF
zone "${LAB_DOMAIN}" {
  type master;
  file "/etc/bind/db.${LAB_DOMAIN}";
};
zone "rpz-helios" {
  type master;
  file "/etc/bind/db.rpz-helios";
};
EOF
  # Older setup versions stored lab.lxc directly in named.conf.local. Remove
  # only that managed block, preserve application zones such as terna.it, and
  # include the dedicated infrastructure file exactly once.
  lxc_retry exec server-dns -- bash -lc '
    set -euo pipefail
    touch /etc/bind/named.conf.local
    sed -i '\''/^zone "lab\.lxc" {/,/^};$/d'\'' /etc/bind/named.conf.local
    grep -Fqx '\''include "/etc/bind/named.conf.d/lxc-lab.conf";'\'' /etc/bind/named.conf.local \
      || printf '\''include "/etc/bind/named.conf.d/lxc-lab.conf";\n'\'' >>/etc/bind/named.conf.local
  '

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
vault-openbao IN A 10.10.3.80
vault IN A 10.10.3.80
git-server IN A 10.10.3.70
ansible-node IN A 10.10.3.100
EOF
  lxc_retry exec server-dns -- bash -lc "cat >/etc/bind/named.conf.d/helios-rpz-options.conf" <<'EOF'
response-policy { zone "rpz-helios"; };
EOF
  lxc_retry exec server-dns -- bash -lc "cat >/etc/bind/db.rpz-helios" <<EOF
\$TTL 30
@ IN SOA server-dns.${LAB_DOMAIN}. admin.${LAB_DOMAIN}. (
  2026090601 30 15 604800 30
)
@ IN NS server-dns.${LAB_DOMAIN}.
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

  # Ubuntu 24.04 does not ship an `lxd-client` APT package. Install only the
  # Snap client, stop its nested daemon, then let Terna reconciliation attach
  # the host LXD socket through a proxy device.
  lxc_retry exec ansible-node -- bash -lc '
    set -euo pipefail
    if ! snap list lxd >/dev/null 2>&1; then
      snap install lxd --channel=5.21/stable
    fi
    snap stop --disable lxd || true
    ln -sfn /snap/bin/lxc /usr/local/bin/lxc
    rm -f /var/snap/lxd/common/lxd/unix.socket
    install -d -m 0755 /var/snap/lxd/common/lxd
  '

  lxc_retry exec ansible-node -- install -d /etc/ansible
  lxc_retry exec ansible-node -- bash -lc "cat >/etc/ansible/hosts" <<EOF
[datacenter]
k3s-datacenter ansible_host=10.10.3.10
vault-openbao ansible_host=10.10.3.80
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
    "vault-openbao 10.10.3.1"
    "pc-dipendente1 10.10.1.1"
  )
  local entry node gateway
  for entry in "${nodes[@]}"; do
    node="${entry%% *}"
    gateway="${entry##* }"
    wait_for_cloud_init "${node}"
    apt_install "${node}" iproute2 iputils-ping dnsutils curl ca-certificates python3
    configure_ubuntu_host "${node}"
    use_lab_route "${node}" "${gateway}"
  done
}

remove_all_provisioning_nics() {
  local nodes=(ansible-node git-server k3s-datacenter pc-dipendente1 server-dns vault-openbao)
  local node
  for node in "${nodes[@]}"; do
    remove_provisioning_nic "${node}"
  done
}

openwrt_exec() {
  local container="$1"
  shift
  # A login shell prints the OpenWrt banner on every retry and obscures the
  # actual failure. No profile state is required for these absolute commands.
  lxc_retry exec "${container}" -- ash -c "$*"
}

configure_openwrt_firewall() {
  local container="$1"
  openwrt_exec "${container}" '
    set -e
    /etc/init.d/firewall stop >/dev/null 2>&1 || true
    /etc/init.d/firewall disable >/dev/null 2>&1 || true
    command -v nft >/dev/null 2>&1 && nft flush ruleset || true
    mkdir -p /etc/sysctl.d
    cat >/etc/sysctl.d/99-lxc-lab-router.conf <<EOF
net.ipv4.ip_forward=1
net.ipv4.icmp_echo_ignore_all=0
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
EOF
    sysctl -p /etc/sysctl.d/99-lxc-lab-router.conf >/dev/null
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
    # OpenWrt 24.10 can block in `ubus call network.interface dump` when a
    # full network restart runs inside LXC/WSL. UCI remains the persistent
    # source of truth; apply the same state directly for the current boot.
    ip link set eth0 up
    ip link set eth1 up
    ip address replace 10.10.1.1/24 dev eth0
    ip address replace 10.10.2.2/24 dev eth1
    ip route replace 10.10.3.0/24 via 10.10.2.3 dev eth1
    ip route replace default via 10.10.2.4 dev eth1
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
    ip link set eth0 up
    ip link set eth1 up
    ip address replace 10.10.3.1/24 dev eth0
    ip address replace 10.10.2.3/24 dev eth1
    ip route replace 10.10.1.0/24 via 10.10.2.2 dev eth1
    ip route replace default via 10.10.2.4 dev eth1
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
    ip link set eth0 up
    ip link set eth1 up
    ip address replace 10.10.2.4/24 dev eth0
    ip address replace 10.10.4.1/24 dev eth1
    ip route replace 10.10.1.0/24 via 10.10.2.2 dev eth0
    ip route replace 10.10.3.0/24 via 10.10.2.3 dev eth0
    ip route replace default via 10.10.4.2 dev eth1
  '
  configure_openwrt_firewall router-dmz
}

configure_router_edge() {
  reset_openwrt_network_defaults router-edge
  openwrt_exec router-edge '
    set -e
    uci -q delete network.route_dipendenti || true
    uci -q delete network.route_dmz || true
    uci -q delete network.route_dc || true
    uci batch <<EOF
set network.transit=interface
set network.transit.device=eth0
set network.transit.proto=static
set network.transit.ipaddr=10.10.4.2
set network.transit.netmask=255.255.255.0
set network.wan=interface
set network.wan.device=eth1
set network.wan.proto=dhcp
set network.route_dipendenti=route
set network.route_dipendenti.interface=transit
set network.route_dipendenti.target=10.10.1.0
set network.route_dipendenti.netmask=255.255.255.0
set network.route_dipendenti.gateway=10.10.4.1
set network.route_dmz=route
set network.route_dmz.interface=transit
set network.route_dmz.target=10.10.2.0
set network.route_dmz.netmask=255.255.255.0
set network.route_dmz.gateway=10.10.4.1
set network.route_dc=route
set network.route_dc.interface=transit
set network.route_dc.target=10.10.3.0
set network.route_dc.netmask=255.255.255.0
set network.route_dc.gateway=10.10.4.1
commit network
EOF
    ip link set eth0 up
    ip link set eth1 up
    ip address replace 10.10.4.2/24 dev eth0
    ip route replace 10.10.1.0/24 via 10.10.4.1 dev eth0
    ip route replace 10.10.2.0/24 via 10.10.4.1 dev eth0
    ip route replace 10.10.3.0/24 via 10.10.4.1 dev eth0
    ifup wan >/dev/null 2>&1 || true

    # dnsmasq must serve the isolated lab on the transit interface. Without an
    # explicit interface OpenWrt may answer only on loopback after a WAN flap.
    # `uci delete` returns 1 when the option is already absent. That is the
    # desired idempotent state, so it must not abort this block under `set -e`.
    uci -q delete dhcp.@dnsmasq[0].interface || true
    uci -q delete dhcp.@dnsmasq[0].listen_address || true
    uci add_list dhcp.@dnsmasq[0].interface=transit
    uci add_list dhcp.@dnsmasq[0].listen_address=127.0.0.1
    uci add_list dhcp.@dnsmasq[0].listen_address=10.10.4.2
    uci set dhcp.@dnsmasq[0].nonwildcard=1
    uci set dhcp.@dnsmasq[0].localservice=0
    uci commit dhcp
    /etc/init.d/dnsmasq restart

    # Routed lab clients legitimately arrive on transit with a source address
    # from another lab subnet. Persist loose reverse-path filtering so the
    # router remains valid after an LXD or WSL restart.
    mkdir -p /etc/sysctl.d
    cat >/etc/sysctl.d/99-lxc-lab-edge.conf <<EOF
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
net.ipv4.conf.eth0.rp_filter=2
net.ipv4.conf.eth1.rp_filter=2
EOF
    sysctl -p /etc/sysctl.d/99-lxc-lab-edge.conf >/dev/null

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

verify_wan_dns_path() {
  local answer attempt recursive_answer tcp_answer
  for attempt in $(seq 1 5); do
    answer="$(lxc exec k3s-datacenter -- dig @10.10.4.2 +time=2 +tries=1 +short registry-1.docker.io A 2>/dev/null || true)"
    tcp_answer="$(lxc exec k3s-datacenter -- dig +tcp @10.10.4.2 +time=2 +tries=1 +short registry-1.docker.io A 2>/dev/null || true)"
    recursive_answer="$(lxc exec k3s-datacenter -- dig @10.10.2.53 +time=4 +tries=1 +short registry-1.docker.io A 2>/dev/null || true)"
    if grep -Eq '^[0-9]+(\.[0-9]+){3}$' <<<"${answer}" \
      && grep -Eq '^[0-9]+(\.[0-9]+){3}$' <<<"${tcp_answer}" \
      && grep -Eq '^[0-9]+(\.[0-9]+){3}$' <<<"${recursive_answer}"; then
      echo "WAN and recursive DNS paths ready (${answer##*$'\n'})."
      return 0
    fi
    lxc exec router-edge -- ifup wan >/dev/null 2>&1 || true
    lxc exec router-edge -- /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
    lxc exec server-dns -- systemctl restart named >/dev/null 2>&1 || true
    sleep 3
  done

  echo 'WAN DNS is unavailable from the datacenter path; collecting hop-by-hop diagnostics.' >&2
  lxc exec router-edge -- nslookup www.terna.it 127.0.0.1 >&2 || true
  lxc exec router-dmz -- nslookup registry-1.docker.io 10.10.4.2 >&2 || true
  lxc exec k3s-datacenter -- ip route get 10.10.4.2 >&2 || true
  lxc exec router-edge -- ip route get 10.10.3.10 >&2 || true
  lxc exec router-edge -- busybox netstat -lnup >&2 || true
  lxc exec router-edge -- logread -e dnsmasq >&2 || true
  return 1
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

  # OpenBao custodisce i segreti del sito DR: come il coordinatore DR deve
  # ripartire da solo dopo un riavvio di LXD/WSL, altrimenti al momento del
  # failover nessun pod potrebbe materializzare le proprie credenziali.
  init_container vault-openbao "${UBUNTU_IMAGE}"
  configure_container_runtime vault-openbao ubuntu-service true
  attach_nic vault-openbao "${NET_DATACENTER}" eth0 10.10.3.80
  attach_provisioning_nic vault-openbao

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
  attach_nic router-edge lxdbr0 eth1

  for container in \
    router-dipendenti router-datacenter router-dmz router-edge \
    ansible-node git-server k3s-datacenter pc-dipendente1 server-dns \
    vault-openbao; do
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
  verify_wan_dns_path
  bash "${SCRIPT_DIR}/../terna-static-dr/bin/reconcile-lxc-lab.sh"
  remove_all_provisioning_nics

  if [ "${LXC_LAB_HOST_DNS:-false}" = "true" ]; then
    bash "${SCRIPT_DIR}/host-dns.sh" enable
  fi

  lxc_retry list
  echo "LXC lab ready."
}

main "$@"
