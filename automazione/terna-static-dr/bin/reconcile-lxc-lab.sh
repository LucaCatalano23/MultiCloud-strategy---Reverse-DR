#!/usr/bin/env bash
set -euo pipefail

# Reconciles only the Terna Static DR resources. Called by lxc-lab/setup.sh.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_SOURCE="${TERNA_DR_CONFIG_SOURCE:-${ROOT_DIR}/config.lxc-lab.env}"
CONFIG_TEMPLATE="${ROOT_DIR}/config.lxc-lab.env.example"
K3S_NODE="k3s-datacenter"
ANSIBLE_NODE="ansible-node"
NAMESPACE="terna-static-dr"
LXD_SOCKET="/var/snap/lxd/common/lxd/unix.socket"
PUBLIC_DNS_PATH_READY=false

instance_running() {
  [ "$(lxc list "$1" -c s --format csv 2>/dev/null | tr '[:lower:]' '[:upper:]' | tr -d '\r\n')" = RUNNING ]
}

ensure_instance_started() {
  local instance="$1" attempt
  # These instances form the minimum runtime path for the scheduled Terna
  # acquisition. Persisting autostart prevents another LXD/WSL restart from
  # leaving only the coordinator alive.
  lxc config set "${instance}" boot.autostart true
  if instance_running "${instance}"; then
    return 0
  fi

  echo "Starting required LXC instance ${instance}."
  # A concurrent LXD autostart may win between the state check and this call.
  # The readiness loop below is authoritative, so an "already running" error
  # from start itself is harmless.
  lxc start "${instance}" >/dev/null 2>&1 || true
  for attempt in $(seq 1 60); do
    if instance_running "${instance}"; then
      return 0
    fi
    sleep 1
  done

  echo "Required LXC instance ${instance} did not reach RUNNING state." >&2
  return 1
}

dr_marker_is_active() {
  lxc exec "${K3S_NODE}" -- test -f /srv/terna-static-dr/static/dr-active
}

ensure_terna_runtime_instances() {
  # Start the two nodes first so the persistent DR marker can be inspected
  # before deciding whether the public-WAN path may be restored.
  ensure_instance_started "${K3S_NODE}"
  ensure_instance_started "${ANSIBLE_NODE}"

  ensure_instance_started router-datacenter
  ensure_instance_started server-dns
  if dr_marker_is_active; then
    echo 'DR is active: leaving the public-WAN containers in their current state.'
    return 0
  fi

  ensure_instance_started router-edge
  ensure_instance_started router-dmz
}

ensure_internal_router_runtime_configuration() {
  echo 'Reconciling the internal LXC router path without restarting OpenWrt networking.'
  lxc exec router-datacenter -- ash -c '
    set -e
    ip link set eth0 up
    ip link set eth1 up
    ip address flush dev eth0
    ip address flush dev eth1
    ip address replace 10.10.3.1/24 dev eth0
    ip address replace 10.10.2.3/24 dev eth1
    ip route replace 10.10.1.0/24 via 10.10.2.2 dev eth1
    ip route replace default via 10.10.2.4 dev eth1
    /etc/init.d/firewall stop >/dev/null 2>&1 || true
    /etc/init.d/firewall disable >/dev/null 2>&1 || true
    command -v nft >/dev/null 2>&1 && nft flush ruleset || true
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    sysctl -w net.ipv4.icmp_echo_ignore_all=0 >/dev/null
    sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null
    sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null
  '
  lxc exec router-dmz -- ash -c '
    set -e
    ip link set eth0 up
    ip link set eth1 up
    ip address flush dev eth0
    ip address flush dev eth1
    ip address replace 10.10.2.4/24 dev eth0
    ip address replace 10.10.4.1/24 dev eth1
    ip route replace 10.10.1.0/24 via 10.10.2.2 dev eth0
    ip route replace 10.10.3.0/24 via 10.10.2.3 dev eth0
    ip route replace default via 10.10.4.2 dev eth1
    /etc/init.d/firewall stop >/dev/null 2>&1 || true
    /etc/init.d/firewall disable >/dev/null 2>&1 || true
    command -v nft >/dev/null 2>&1 && nft flush ruleset || true
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    sysctl -w net.ipv4.icmp_echo_ignore_all=0 >/dev/null
    sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null
    sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null
  '
}

router_edge_runtime_is_ready() {
  lxc exec router-edge -- sh -ec '
    test "$(uci -q get network.route_dipendenti.gateway)" = 10.10.4.1
    test "$(uci -q get network.route_dmz.gateway)" = 10.10.4.1
    test "$(uci -q get network.route_dc.gateway)" = 10.10.4.1
    test "$(uci -q get dhcp.@dnsmasq[0].localservice)" = 0
    uci -q get dhcp.@dnsmasq[0].interface | grep -Fx transit >/dev/null
    uci -q get dhcp.@dnsmasq[0].listen_address | grep -F 10.10.4.2 >/dev/null
    grep -Fxq "net.ipv4.conf.all.rp_filter=2" /etc/sysctl.d/99-lxc-lab-edge.conf
    test "$(uci -q get firewall.@zone[0].name)" = transit
    test "$(uci -q get firewall.@zone[1].name)" = wan
    test "$(uci -q get firewall.@zone[1].masq)" = 1
    test "$(uci -q get firewall.@forwarding[0].src)" = transit
    test "$(uci -q get firewall.@forwarding[0].dest)" = wan
  '
}

ensure_router_edge_runtime_configuration() {
  local attempt
  if dr_marker_is_active; then
    echo 'DR is active: preserving the current router-edge runtime state.'
    return 0
  fi

  for attempt in $(seq 1 30); do
    if lxc exec router-edge -- sh -ec 'command -v uci >/dev/null'; then
      break
    fi
    sleep 1
  done
  lxc exec router-edge -- sh -ec 'command -v uci >/dev/null' || {
    echo 'router-edge did not finish booting.' >&2
    return 1
  }
  if router_edge_runtime_is_ready; then
    return 0
  fi

  echo 'Reconciling router-edge routes, DNS listener and firewall.'
  lxc exec router-edge -- sh -ec '
    uci -q delete network.route_dipendenti || true
    uci -q delete network.route_dmz || true
    uci -q delete network.route_dc || true
    uci batch <<EOF
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

    uci -q delete dhcp.@dnsmasq[0].interface || true
    uci -q delete dhcp.@dnsmasq[0].listen_address || true
    uci add_list dhcp.@dnsmasq[0].interface=transit
    uci add_list dhcp.@dnsmasq[0].listen_address=127.0.0.1
    uci add_list dhcp.@dnsmasq[0].listen_address=10.10.4.2
    uci set dhcp.@dnsmasq[0].nonwildcard=1
    uci set dhcp.@dnsmasq[0].localservice=0
    uci commit dhcp

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
    ip link set eth0 up
    ip address replace 10.10.4.2/24 dev eth0
    ip route replace 10.10.1.0/24 via 10.10.4.1 dev eth0
    ip route replace 10.10.2.0/24 via 10.10.4.1 dev eth0
    ip route replace 10.10.3.0/24 via 10.10.4.1 dev eth0
    ifup wan >/dev/null 2>&1 || true
    /etc/init.d/dnsmasq restart
    /etc/init.d/firewall enable >/dev/null 2>&1 || true
    /etc/init.d/firewall restart
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
  '
  router_edge_runtime_is_ready
}

is_public_ipv4() {
  python3 - "$1" <<'PY'
import ipaddress
import sys

try:
    address = ipaddress.ip_address(sys.argv[1])
except ValueError:
    sys.exit(1)
sys.exit(0 if address.version == 4 and address.is_global else 1)
PY
}

answer_has_public_ipv4() {
  local candidate
  while IFS= read -r candidate; do
    if [[ "${candidate}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] \
      && is_public_ipv4 "${candidate}"; then
      return 0
    fi
  done <<<"$1"
  return 1
}

public_dns_path_ready() {
  local direct_answer recursive_answer
  direct_answer="$(lxc exec "${K3S_NODE}" -- dig @10.10.4.2 +time=3 +tries=1 +short www.terna.it A 2>/dev/null || true)"
  recursive_answer="$(lxc exec "${K3S_NODE}" -- dig @10.10.2.53 +time=4 +tries=1 +short www.terna.it A 2>/dev/null || true)"
  answer_has_public_ipv4 "${direct_answer}" \
    && answer_has_public_ipv4 "${recursive_answer}"
}

ensure_public_dns_path() {
  local attempt
  if public_dns_path_ready; then
    echo 'Terna public DNS path is ready.'
    return 0
  fi
  if dr_marker_is_active; then
    echo 'DR is active: refusing to bring the public WAN up for an origin refresh.' >&2
    return 1
  fi

  for attempt in $(seq 1 5); do
    echo "Repairing the Terna public DNS path (attempt ${attempt}/5)."
    lxc exec router-edge -- ifup wan >/dev/null 2>&1 || true
    lxc exec router-edge -- /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
    lxc exec server-dns -- systemctl restart named >/dev/null 2>&1 || true
    sleep 3
    if public_dns_path_ready; then
      echo 'Terna public DNS path is ready.'
      return 0
    fi
  done

  echo 'Terna public DNS path is still unavailable after recovery attempts.' >&2
  return 1
}

checksum_tree() {
  find "$1" -type f ! -name config.lxc-lab.env -print0 | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}'
}

controller_checksum() {
  find "${ROOT_DIR}/bin" "${ROOT_DIR}/ansible" "${ROOT_DIR}/systemd" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}'
}

ensure_lxd_socket_proxy() {
  if lxc exec "${ANSIBLE_NODE}" -- test -S "${LXD_SOCKET}" \
    && lxc exec "${ANSIBLE_NODE}" -- /usr/local/bin/lxc list --format=compact >/dev/null 2>&1; then
    return 0
  fi

  echo 'Repairing the LXD socket proxy on ansible-node.'
  if lxc config device show "${ANSIBLE_NODE}" | grep -q '^lxd-socket:'; then
    lxc config device remove "${ANSIBLE_NODE}" lxd-socket
  fi

  # The client is needed inside the controller node, while the proxy supplies
  # only the host LXD API socket.  Remove a stale socket before recreating it.
  lxc exec "${ANSIBLE_NODE}" -- bash -lc '
    set -euo pipefail
    if ! snap list lxd >/dev/null 2>&1; then
      snap install lxd --channel=5.21/stable
    fi
    snap stop --disable lxd || true
    ln -sfn /snap/bin/lxc /usr/local/bin/lxc
    rm -f /var/snap/lxd/common/lxd/unix.socket
    install -d -m 0755 /var/snap/lxd/common/lxd
  '
  lxc config device add "${ANSIBLE_NODE}" lxd-socket proxy \
    "listen=unix:${LXD_SOCKET}" "connect=unix:${LXD_SOCKET}" bind=instance uid=0 gid=0 mode=0660
  lxc exec "${ANSIBLE_NODE}" -- test -S "${LXD_SOCKET}"
  lxc exec "${ANSIBLE_NODE}" -- /usr/local/bin/lxc list --format=compact >/dev/null
}

ensure_k3s() {
  if ! lxc exec "${K3S_NODE}" -- test -x /usr/local/bin/k3s; then
    echo 'K3s is missing on k3s-datacenter; installing it once.'
    # Required for K3s running inside this privileged LXC container.
    lxc exec "${K3S_NODE}" -- ln -sf /dev/console /dev/kmsg
    lxc exec "${K3S_NODE}" -- bash -lc 'cat >/etc/tmpfiles.d/k3s-lxc.conf <<EOF
L /dev/kmsg - - - - /dev/console
EOF'
    lxc exec "${K3S_NODE}" -- bash -lc "curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC='--disable traefik=false --write-kubeconfig-mode 644' sh -"
  else
    lxc exec "${K3S_NODE}" -- systemctl enable --now k3s
  fi

  local attempt
  for attempt in $(seq 1 90); do
    if lxc exec "${K3S_NODE}" -- kubectl get nodes >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  echo 'K3s did not become ready on k3s-datacenter.' >&2
  lxc exec "${K3S_NODE}" -- systemctl status k3s --no-pager -l >&2 || true
  return 1
}

ensure_k3s_resolver() {
  local resolver_file='/etc/rancher/k3s/resolv.conf'
  local service_env='/etc/systemd/system/k3s.service.env'
  local resolver_marker='/var/lib/terna-static-dr/k3s-resolver-version'
  if lxc exec "${K3S_NODE}" -- grep -Fxq 'nameserver 10.10.2.53' "${resolver_file}" 2>/dev/null \
    && lxc exec "${K3S_NODE}" -- grep -Fxq 'K3S_RESOLV_CONF=/etc/rancher/k3s/resolv.conf' "${service_env}" 2>/dev/null \
    && lxc exec "${K3S_NODE}" -- grep -Fxq 'server-dns-v1' "${resolver_marker}" 2>/dev/null; then
    return 0
  fi

  echo 'Configuring K3s pod DNS to use the LXC lab DNS server.'
  lxc exec "${K3S_NODE}" -- bash -lc '
    set -euo pipefail
    install -d -m 0755 /etc/rancher/k3s
    printf "%s\n" "nameserver 10.10.2.53" > /etc/rancher/k3s/resolv.conf
    touch /etc/systemd/system/k3s.service.env
    if grep -q "^K3S_RESOLV_CONF=" /etc/systemd/system/k3s.service.env; then
      sed -i "s|^K3S_RESOLV_CONF=.*|K3S_RESOLV_CONF=/etc/rancher/k3s/resolv.conf|" /etc/systemd/system/k3s.service.env
    else
      printf "%s\n" "K3S_RESOLV_CONF=/etc/rancher/k3s/resolv.conf" >> /etc/systemd/system/k3s.service.env
    fi
    chmod 0644 /etc/rancher/k3s/resolv.conf /etc/systemd/system/k3s.service.env
    systemctl daemon-reload
    systemctl restart k3s
  '

  local attempt
  for attempt in $(seq 1 90); do
    if lxc exec "${K3S_NODE}" -- kubectl get nodes >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done
  lxc exec "${K3S_NODE}" -- kubectl get nodes >/dev/null
  # Existing CoreDNS pods retain their old resolv.conf across a kubelet restart.
  lxc exec "${K3S_NODE}" -- kubectl -n kube-system rollout restart deployment/coredns
  lxc exec "${K3S_NODE}" -- kubectl -n kube-system rollout status deployment/coredns --timeout=120s
  lxc exec "${K3S_NODE}" -- install -d -m 0755 /var/lib/terna-static-dr
  lxc exec "${K3S_NODE}" -- sh -c "printf '%s\n' server-dns-v1 > '${resolver_marker}'"
}

ensure_static_images() {
  local nginx_image='docker.io/library/nginx:1.27-alpine'
  local current_images
  current_images="$(lxc exec "${K3S_NODE}" -- k3s ctr -n k8s.io images list -q 2>/dev/null || true)"
  if grep -Fxq "${nginx_image}" <<<"${current_images}"; then
    echo 'The Terna static web image already exists in K3s; skipping import.'
    return 0
  fi

  command -v docker >/dev/null 2>&1 || {
    echo 'Docker is required on the host to preload the Terna static web image into K3s.' >&2
    return 1
  }
  docker info >/dev/null
  docker image inspect nginx:1.27-alpine >/dev/null 2>&1 || docker pull nginx:1.27-alpine
  docker save nginx:1.27-alpine \
    | lxc exec "${K3S_NODE}" -- k3s ctr -n k8s.io images import -
}

ensure_static_storage() {
  # Nginx runs with gid 101. Prepare the hostPath
  # explicitly because Kubernetes does not reliably chmod hostPath volumes on
  # every LXC/K3s combination.
  lxc exec "${K3S_NODE}" -- install -d -m 2770 -o 65534 -g 101 \
    /srv/terna-static-dr/static /srv/terna-static-dr/static/bundles
  # Repair bundles created by older versions where mktemp left the root
  # directory private (0700), making it unreadable by nginx uid/gid 101.
  lxc exec "${K3S_NODE}" -- chgrp -R 101 /srv/terna-static-dr/static/bundles
  lxc exec "${K3S_NODE}" -- chmod -R g+rX /srv/terna-static-dr/static/bundles
}

ensure_chart_browser() {
  if lxc exec "${K3S_NODE}" -- sh -ec \
    'command -v google-chrome >/dev/null && google-chrome --version >/dev/null'; then
    echo 'Google Chrome is already available for Terna chart screenshots.'
    return 0
  fi

  if [ "${PUBLIC_DNS_PATH_READY}" != true ]; then
    echo 'WARNING: Chrome is unavailable and public DNS is down; skipping browser installation.' >&2
    return 0
  fi

  echo 'Installing Google Chrome on k3s-datacenter for Terna chart screenshots.'
  if ! lxc exec "${K3S_NODE}" -- env DEBIAN_FRONTEND=noninteractive apt-get update; then
    echo 'WARNING: Chrome package metadata could not be refreshed; screenshot capture will use its fallback.' >&2
    return 0
  fi
  # Ubuntu Noble ships Chromium as a Snap transitional package. Snap cannot
  # create the mount namespace it needs inside this LXC, so use the official
  # Google Chrome .deb instead.
  if ! lxc exec "${K3S_NODE}" -- bash -lc '
    set -euo pipefail
    dpkg --purge --force-all chromium chromium-browser 2>/dev/null || true
    package="$(mktemp /tmp/google-chrome.XXXXXX.deb)"
    trap "rm -f -- \"${package}\"" EXIT
    curl --fail --silent --show-error --location --retry 3 --retry-all-errors \
      --connect-timeout 15 --max-time 180 \
      https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb \
      --output "${package}"
    env DEBIAN_FRONTEND=noninteractive apt-get install -y "${package}"
  '; then
    echo 'WARNING: Chrome installation failed; screenshot capture will use its fallback.' >&2
    return 0
  fi
  if ! lxc exec "${K3S_NODE}" -- sh -ec \
    'command -v google-chrome >/dev/null && google-chrome --version >/dev/null'; then
    echo 'WARNING: Chrome installation completed without a usable browser; screenshot capture will use its fallback.' >&2
    return 0
  fi
}

current_bundle_is_valid() {
  lxc exec "${K3S_NODE}" -- test -s /srv/terna-static-dr/static/current/manifest.json \
    && lxc exec "${K3S_NODE}" -- test -f /srv/terna-static-dr/static/current/.bundle-v1 \
    && lxc exec "${K3S_NODE}" -- test -s /srv/terna-static-dr/static/current/dr/load-chart/index.html \
    && lxc exec "${K3S_NODE}" -- test -s /srv/terna-static-dr/static/current/dr/load-chart/data.json \
    && lxc exec "${K3S_NODE}" -- sh -ec \
      'chart=/srv/terna-static-dr/static/current/dr/load-chart; test -f "${chart}/.load-chart-v1" || test -f "${chart}/.load-chart-placeholder-v1"'
}

ensure_origin_fetcher() {
  local marker='/var/lib/terna-static-dr/origin-fetcher-checksum'
  local desired_hash current_hash refresh_required=false dr_active=false
  # The chart is now a public screenshot: discard credentials left by older
  # API-based installations so they cannot be mistaken for active settings.
  lxc exec "${K3S_NODE}" -- rm -f \
    /etc/terna-static-dr/terna-api-client-id \
    /etc/terna-static-dr/terna-api-client-secret
  desired_hash="$(sha256sum \
    "${ROOT_DIR}/host-fetch/terna-static-origin-fetch.sh" \
    "${ROOT_DIR}/host-fetch/build-static-bundle.py" \
    "${ROOT_DIR}/host-fetch/build-load-screenshot.py" \
    "${ROOT_DIR}/host-fetch/load_chart_capture.py" \
    "${ROOT_DIR}/host-fetch/chrome_devtools_capture.py" \
    "${ROOT_DIR}/systemd/terna-static-origin-fetch.service" \
    "${ROOT_DIR}/systemd/terna-static-origin-fetch.timer" | sha256sum | awk '{print $1}')"
  current_hash="$(lxc exec "${K3S_NODE}" -- cat "${marker}" 2>/dev/null || true)"

  if [ "${current_hash}" != "${desired_hash}" ]; then
    echo 'Installing the K3s-host Terna origin fetcher.'
    lxc exec "${K3S_NODE}" -- install -d -m 0755 \
      /usr/local/lib/terna-static-dr /var/lib/terna-static-dr
    lxc file push "${ROOT_DIR}/host-fetch/terna-static-origin-fetch.sh" \
      "${K3S_NODE}/usr/local/lib/terna-static-dr/terna-static-origin-fetch.sh" \
      --mode=0755 --uid=0 --gid=0
    lxc file push "${ROOT_DIR}/host-fetch/build-static-bundle.py" \
      "${K3S_NODE}/usr/local/lib/terna-static-dr/build-static-bundle.py" \
      --mode=0755 --uid=0 --gid=0
    lxc file push "${ROOT_DIR}/host-fetch/build-load-screenshot.py" \
      "${K3S_NODE}/usr/local/lib/terna-static-dr/build-load-screenshot.py" \
      --mode=0755 --uid=0 --gid=0
    lxc file push "${ROOT_DIR}/host-fetch/load_chart_capture.py" \
      "${K3S_NODE}/usr/local/lib/terna-static-dr/load_chart_capture.py" \
      --mode=0644 --uid=0 --gid=0
    lxc file push "${ROOT_DIR}/host-fetch/chrome_devtools_capture.py" \
      "${K3S_NODE}/usr/local/lib/terna-static-dr/chrome_devtools_capture.py" \
      --mode=0644 --uid=0 --gid=0
    lxc file push "${ROOT_DIR}/systemd/terna-static-origin-fetch.service" \
      "${K3S_NODE}/etc/systemd/system/terna-static-origin-fetch.service" \
      --mode=0644 --uid=0 --gid=0
    lxc file push "${ROOT_DIR}/systemd/terna-static-origin-fetch.timer" \
      "${K3S_NODE}/etc/systemd/system/terna-static-origin-fetch.timer" \
      --mode=0644 --uid=0 --gid=0
    lxc exec "${K3S_NODE}" -- systemctl daemon-reload
    lxc exec "${K3S_NODE}" -- sh -c "printf '%s\n' '${desired_hash}' > '${marker}'"
    # A new builder must produce a new bundle; otherwise a valid-but-old
    # snapshot would continue to be served until a separate failure or timer.
    refresh_required=true
  else
    echo 'Terna origin fetcher already matches; skipping install.'
  fi

  lxc exec "${K3S_NODE}" -- systemctl enable --now terna-static-origin-fetch.timer
  lxc exec "${K3S_NODE}" -- test -x /usr/bin/python3 || {
    echo 'python3 is missing on k3s-datacenter; rerun lxc-lab/setup.sh once.' >&2
    return 1
  }
  if lxc exec "${K3S_NODE}" -- test -f /srv/terna-static-dr/static/dr-active; then
    dr_active=true
  fi
  if ! current_bundle_is_valid; then
    refresh_required=true
  fi

  if [ "${refresh_required}" = true ]; then
    if [ "${dr_active}" = true ]; then
      echo 'DR is active: building the replacement bundle without changing the lab DNS zone.'
      if ! lxc exec "${K3S_NODE}" -- env TERNA_DR_ALLOW_REFRESH_DURING_DR=true \
        /usr/local/lib/terna-static-dr/terna-static-origin-fetch.sh; then
        echo 'DR migration refresh failed; the currently published snapshot and DNS zone were preserved.' >&2
        if ! current_bundle_is_valid; then
          return 1
        fi
        echo 'WARNING: continuing with the last valid Terna static bundle.' >&2
      fi
    elif ! lxc exec "${K3S_NODE}" -- systemctl start terna-static-origin-fetch.service; then
      lxc exec "${K3S_NODE}" -- journalctl -u terna-static-origin-fetch.service -n 50 --no-pager >&2 || true
      if ! current_bundle_is_valid; then
        return 1
      fi
      echo 'WARNING: origin refresh failed; continuing with the last valid Terna static bundle.' >&2
    fi
  fi

  current_bundle_is_valid || {
    echo 'The K3s host did not produce a valid Terna static bundle.' >&2
    return 1
  }
  if ! lxc exec "${K3S_NODE}" -- test -f /srv/terna-static-dr/static/current/dr/load-chart/.load-chart-v1; then
    echo 'WARNING: Terna chart data is unavailable; the placeholder is valid and DR failover remains available.' >&2
  fi
}

reconcile_static_pod() {
  local desired_hash current_hash staging_dir
  desired_hash="$(checksum_tree "${ROOT_DIR}/kubernetes")"
  current_hash="$(lxc exec "${K3S_NODE}" -- kubectl -n "${NAMESPACE}" get deployment terna-static-web -o 'jsonpath={.metadata.annotations.lxc-lab\.terna-static-dr/checksum}' 2>/dev/null || true)"
  if [ "${current_hash}" = "${desired_hash}" ] && lxc exec "${K3S_NODE}" -- kubectl -n "${NAMESPACE}" rollout status deployment/terna-static-web --timeout=10s >/dev/null 2>&1; then
    echo 'Terna static DR Kubernetes resources already match; skipping apply.'
    return 0
  fi
  staging_dir="$(lxc exec "${K3S_NODE}" -- mktemp -d /tmp/terna-static-dr-kubernetes.XXXXXX)"
  [[ "${staging_dir}" =~ ^/tmp/terna-static-dr-kubernetes\.[A-Za-z0-9]+$ ]] || { echo 'Unsafe Kubernetes staging path.' >&2; return 1; }
  tar -C "${ROOT_DIR}/kubernetes" -cf - . | lxc exec "${K3S_NODE}" -- tar -C "${staging_dir}" -xf -
  lxc exec "${K3S_NODE}" -- kubectl apply -k "${staging_dir}"
  # `kubectl apply -k` does not prune resources removed from Kustomize.
  lxc exec "${K3S_NODE}" -- kubectl -n "${NAMESPACE}" delete cronjob terna-static-mirror --ignore-not-found
  lxc exec "${K3S_NODE}" -- kubectl -n "${NAMESPACE}" delete configmap terna-static-mirror-script --ignore-not-found
  lxc exec "${K3S_NODE}" -- kubectl -n "${NAMESPACE}" delete jobs -l app=terna-static-mirror --ignore-not-found
  lxc exec "${K3S_NODE}" -- kubectl -n "${NAMESPACE}" annotate deployment/terna-static-web "lxc-lab.terna-static-dr/checksum=${desired_hash}" --overwrite
  lxc exec "${K3S_NODE}" -- test -s /srv/terna-static-dr/static/current/index.html
  lxc exec "${K3S_NODE}" -- test -s /srv/terna-static-dr/static/current/manifest.json
  lxc exec "${K3S_NODE}" -- test -f /srv/terna-static-dr/static/current/.bundle-v1
  lxc exec "${K3S_NODE}" -- test -s /srv/terna-static-dr/static/current/dr/load-chart/index.html
  lxc exec "${K3S_NODE}" -- test -s /srv/terna-static-dr/static/current/dr/load-chart/data.json
  lxc exec "${K3S_NODE}" -- sh -ec \
    'chart=/srv/terna-static-dr/static/current/dr/load-chart; test -f "${chart}/.load-chart-v1" || test -f "${chart}/.load-chart-placeholder-v1"'
  echo 'Static bundle is published; starting a fresh Terna static web rollout.'
  lxc exec "${K3S_NODE}" -- kubectl -n "${NAMESPACE}" rollout restart deployment/terna-static-web
  if ! lxc exec "${K3S_NODE}" -- kubectl -n "${NAMESPACE}" rollout status deployment/terna-static-web --timeout=180s; then
    echo 'Terna static DR pod did not become ready; Kubernetes events follow.' >&2
    lxc exec "${K3S_NODE}" -- kubectl -n "${NAMESPACE}" get pods -o wide >&2 || true
    lxc exec "${K3S_NODE}" -- kubectl -n "${NAMESPACE}" describe pods >&2 || true
    return 1
  fi
  lxc exec "${K3S_NODE}" -- rm -rf -- "${staging_dir}"
}

reconcile_controller() {
  local desired_hash current_hash config_value config_hash remote_config_hash
  desired_hash="$(controller_checksum)"
  current_hash="$(lxc exec "${ANSIBLE_NODE}" -- cat /opt/terna-static-dr/.provision-checksum 2>/dev/null || true)"
  if [ "${current_hash}" != "${desired_hash}" ]; then
    lxc exec "${ANSIBLE_NODE}" -- systemctl stop terna-static-dr-controller.service 2>/dev/null || true
    lxc exec "${ANSIBLE_NODE}" -- rm -rf /opt/terna-static-dr
    lxc exec "${ANSIBLE_NODE}" -- install -d -m 0755 /opt/terna-static-dr
    tar -C "${ROOT_DIR}" --exclude='./config.lxc-lab.env' -cf - . | lxc exec "${ANSIBLE_NODE}" -- tar -C /opt/terna-static-dr -xf -
    lxc exec "${ANSIBLE_NODE}" -- sh -c "printf '%s\\n' '${desired_hash}' >/opt/terna-static-dr/.provision-checksum"
    lxc exec "${ANSIBLE_NODE}" -- install -m 0644 /opt/terna-static-dr/systemd/terna-static-dr-controller.service /etc/systemd/system/terna-static-dr-controller.service
    lxc exec "${ANSIBLE_NODE}" -- ansible-playbook -i /opt/terna-static-dr/ansible/inventory.ini /opt/terna-static-dr/ansible/playbooks/terna-static-dr-failover.yml --syntax-check
    lxc exec "${ANSIBLE_NODE}" -- systemctl daemon-reload
  else
    echo 'Terna static DR controller source already matches; skipping copy.'
  fi
  lxc exec "${ANSIBLE_NODE}" -- install -d -m 0700 /etc/terna-static-dr /var/lib/terna-static-dr
  if [ -r "${CONFIG_SOURCE}" ]; then
    config_hash="$(sha256sum "${CONFIG_SOURCE}" | awk '{print $1}')"
    remote_config_hash="$(lxc exec "${ANSIBLE_NODE}" -- cat /etc/terna-static-dr/.source-config-checksum 2>/dev/null || true)"
    if [ "${remote_config_hash}" != "${config_hash}" ]; then
      lxc file push "${CONFIG_SOURCE}" "${ANSIBLE_NODE}/etc/terna-static-dr/config.env" --mode=0600 --uid=0 --gid=0
      lxc exec "${ANSIBLE_NODE}" -- sh -c "printf '%s\\n' '${config_hash}' >/etc/terna-static-dr/.source-config-checksum"
    else
      echo 'Terna controller configuration already matches; skipping copy.'
    fi
  elif ! lxc exec "${ANSIBLE_NODE}" -- test -f /etc/terna-static-dr/config.env; then
    CONFIG_SOURCE="${CONFIG_TEMPLATE}"
    lxc file push "${CONFIG_SOURCE}" "${ANSIBLE_NODE}/etc/terna-static-dr/config.env" --mode=0600 --uid=0 --gid=0
  fi
  # Files edited from Windows may contain CRLF. Normalize the deployed copy so
  # both this comparison and `source config.env` inside the controller see
  # exactly `true`, not the hidden value `true\r`.
  lxc exec "${ANSIBLE_NODE}" -- sed -i 's/\r$//' /etc/terna-static-dr/config.env
  config_value="$(lxc exec "${ANSIBLE_NODE}" -- sed -n 's/^TERNA_DR_AUTO_FAILOVER_ENABLED=//p' /etc/terna-static-dr/config.env \
    | tail -n 1 | tr -d '\r[:space:]')"
  if [ "${config_value}" = true ]; then
    lxc exec "${ANSIBLE_NODE}" -- env TERNA_DR_CONFIG_FILE=/etc/terna-static-dr/config.env bash /opt/terna-static-dr/bin/lxc-lab-controller.sh validate
    lxc exec "${ANSIBLE_NODE}" -- systemctl enable --now terna-static-dr-controller.service
    lxc exec "${ANSIBLE_NODE}" -- systemctl is-active --quiet terna-static-dr-controller.service
  else
    lxc exec "${ANSIBLE_NODE}" -- systemctl disable --now terna-static-dr-controller.service 2>/dev/null || true
    echo 'Terna controller remains unarmed; set TERNA_DR_AUTO_FAILOVER_ENABLED=true to start it.'
  fi
}

main() {
  command -v lxc >/dev/null 2>&1 || { echo 'lxc is required.' >&2; return 1; }
  lxc info "${K3S_NODE}" >/dev/null
  lxc info "${ANSIBLE_NODE}" >/dev/null
  ensure_terna_runtime_instances
  ensure_internal_router_runtime_configuration
  ensure_router_edge_runtime_configuration
  ensure_lxd_socket_proxy
  ensure_k3s
  ensure_k3s_resolver
  if ensure_public_dns_path; then
    PUBLIC_DNS_PATH_READY=true
  else
    echo 'WARNING: public DNS is unavailable; a valid existing bundle will be preserved.' >&2
  fi
  ensure_static_storage
  ensure_chart_browser
  ensure_origin_fetcher
  ensure_static_images
  reconcile_static_pod
  reconcile_controller
}

if [ "${TERNA_RECONCILE_SOURCE_ONLY:-false}" != true ]; then
  main "$@"
fi
