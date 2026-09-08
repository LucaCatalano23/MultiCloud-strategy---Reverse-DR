#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

require_file() { test -f "${ROOT_DIR}/$1" || { echo "Missing $1" >&2; exit 1; }; }
require_text() { grep -Fq -- "$2" "${ROOT_DIR}/$1" || { echo "Missing '$2' in $1" >&2; exit 1; }; }
reject_text() { ! grep -Fq -- "$2" "${ROOT_DIR}/$1" || { echo "Unexpected '$2' in $1" >&2; exit 1; }; }

require_file bin/lxc-lab-controller.sh
require_file bin/install-on-ansible-node.sh
require_file bin/deploy-static-pod.sh
require_file kubernetes/kustomization.yaml
require_file kubernetes/deployment.yaml
require_file host-fetch/terna-static-origin-fetch.sh
require_file host-fetch/build-static-bundle.py
require_file host-fetch/build-load-screenshot.py
require_file host-fetch/load_chart_capture.py
require_file host-fetch/chrome_devtools_capture.py
require_file systemd/terna-static-origin-fetch.service
require_file systemd/terna-static-origin-fetch.timer
require_file kubernetes/ingress.yaml
require_file kubernetes/namespace.yaml
require_file systemd/terna-static-dr-controller.service

require_text bin/lxc-lab-controller.sh 'hostname -s'
require_text bin/lxc-lab-controller.sh 'ansible-node'
require_text bin/lxc-lab-controller.sh 'lxc exec'
require_text bin/lxc-lab-controller.sh 'server-dns'
require_text bin/lxc-lab-controller.sh 'named-checkconf'
require_text bin/lxc-lab-controller.sh 'systemctl reload named'
require_text bin/lxc-lab-controller.sh 'terna.it'
require_text bin/lxc-lab-controller.sh 'delete-lab-zone'
require_text bin/lxc-lab-controller.sh 'dr-active'
require_text bin/lxc-lab-controller.sh 'dig +short'
require_text bin/lxc-lab-controller.sh 'TERNA_PUBLIC_DNS_RESOLVER'
require_text bin/lxc-lab-controller.sh 'TERNA_PUBLIC_DNS_RESOLVER:-10.10.4.2'
require_text config.lxc-lab.env.example 'TERNA_PUBLIC_DNS_RESOLVER=10.10.4.2'
require_text bin/lxc-lab-controller.sh 'TERNA_STATIC_HEALTH_URL'
require_text systemd/terna-static-dr-controller.service 'Environment=HOME=/var/lib/terna-static-dr'
require_text systemd/terna-static-dr-controller.service 'Environment=ANSIBLE_LOCAL_TEMP=/var/lib/terna-static-dr/.ansible/tmp'
require_text systemd/terna-static-dr-controller.service 'Environment=ANSIBLE_REMOTE_TEMP=/var/lib/terna-static-dr/.ansible/tmp'
require_text bin/install-on-ansible-node.sh 'lxc file push'
require_text bin/install-on-ansible-node.sh 'terna-static-dr-controller.service'
require_text bin/install-on-ansible-node.sh 'TERNA_DR_AUTO_FAILOVER_ENABLED'
require_text bin/deploy-static-pod.sh 'k3s-datacenter'
require_text kubernetes/namespace.yaml 'name: terna-static-dr'
require_text kubernetes/deployment.yaml 'name: static-web'
require_text kubernetes/deployment.yaml 'test -f /usr/share/nginx/html/current/.bundle-v1'
require_text kubernetes/deployment.yaml 'test -s /usr/share/nginx/html/current/manifest.json'
require_text kubernetes/deployment.yaml 'test -s /usr/share/nginx/html/current/dr/load-chart/index.html'
require_text kubernetes/deployment.yaml 'test -s /usr/share/nginx/html/current/dr/load-chart/data.json'
require_text kubernetes/deployment.yaml '.load-chart-placeholder-v1'
require_text kubernetes/deployment.yaml 'runAsUser: 101'
require_text kubernetes/deployment.yaml 'runAsGroup: 101'
require_text kubernetes/deployment.yaml 'runAsNonRoot: true'
require_text kubernetes/deployment.yaml 'command: ["nginx", "-g", "daemon off;"]'
reject_text kubernetes/nginx-config.yaml 'if (!-f'
require_text kubernetes/nginx-config.yaml 'index index.html;'
require_text kubernetes/nginx-config.yaml 'location /assets/'
require_text kubernetes/nginx-config.yaml 'try_files $uri =404;'
require_text kubernetes/nginx-config.yaml 'location = /it'
reject_text kubernetes/deployment.yaml 'name: static-mirror'
reject_text kubernetes/kustomization.yaml 'snapshot-cronjob.yaml'
reject_text kubernetes/kustomization.yaml 'mirror-script.yaml'
require_text bin/reconcile-lxc-lab.sh 'docker save'
reject_text bin/reconcile-lxc-lab.sh 'docker build'
require_text bin/reconcile-lxc-lab.sh '.bundle-v1'
require_text bin/reconcile-lxc-lab.sh 'ensure_origin_fetcher'
require_text bin/reconcile-lxc-lab.sh 'ensure_terna_runtime_instances'
require_text bin/reconcile-lxc-lab.sh 'ensure_router_edge_runtime_configuration'
require_text bin/reconcile-lxc-lab.sh 'ensure_internal_router_runtime_configuration'
reject_text bin/reconcile-lxc-lab.sh '/etc/init.d/network restart'
require_text bin/reconcile-lxc-lab.sh 'ensure_public_dns_path'
require_text bin/reconcile-lxc-lab.sh 'answer_has_public_ipv4'
require_text bin/reconcile-lxc-lab.sh 'current_bundle_is_valid'
require_text bin/reconcile-lxc-lab.sh 'ensure_chart_browser'
require_text bin/reconcile-lxc-lab.sh 'google-chrome-stable_current_amd64.deb'
require_text bin/reconcile-lxc-lab.sh 'terna-static-origin-fetch.timer'
require_text bin/reconcile-lxc-lab.sh 'build-static-bundle.py'
require_text bin/reconcile-lxc-lab.sh 'build-load-screenshot.py'
require_text bin/reconcile-lxc-lab.sh 'load_chart_capture.py'
require_text bin/reconcile-lxc-lab.sh 'chrome_devtools_capture.py'
require_text bin/reconcile-lxc-lab.sh 'test -x /usr/bin/python3'
reject_text bin/reconcile-lxc-lab.sh 'lxc exec "${K3S_NODE}" -- command -v python3'
require_text bin/reconcile-lxc-lab.sh 'TERNA_DR_ALLOW_REFRESH_DURING_DR=true'
require_text host-fetch/terna-static-origin-fetch.sh '--resolve "www.terna.it:443:${origin_ip}"'
require_text host-fetch/terna-static-origin-fetch.sh 'build-static-bundle.py'
require_text host-fetch/terna-static-origin-fetch.sh 'build-load-screenshot.py'
require_text host-fetch/terna-static-origin-fetch.sh 'TERNA_PUBLIC_DNS_RESOLVER:-10.10.4.2'
require_text host-fetch/terna-static-origin-fetch.sh 'local resolvers=("${public_dns_resolver}" 10.10.2.53)'
require_text host-fetch/terna-static-origin-fetch.sh 'TERNA_DR_ALLOW_REFRESH_DURING_DR:-false'
require_text host-fetch/terna-static-origin-fetch.sh '+tries=1'
require_text host-fetch/terna-static-origin-fetch.sh 'flock -w 60'
require_text host-fetch/terna-static-origin-fetch.sh 'API refresh skipped during DR migration'
require_text host-fetch/terna-static-origin-fetch.sh 'previous valid load chart was preserved'
require_text host-fetch/load_chart_capture.py 'attempts: int = 3'
require_text host-fetch/chrome_devtools_capture.py 'report.on("rendered"'
require_text host-fetch/chrome_devtools_capture.py '--remote-debugging-port=0'
require_text host-fetch/chrome_devtools_capture.py 'prepare_browser_identity'
reject_text host-fetch/chrome_devtools_capture.py '--remote-debugging-port=9222'
require_text host-fetch/terna-static-origin-fetch.sh '.load-chart-v1'
require_text host-fetch/terna-static-origin-fetch.sh 'address.is_global'
require_text host-fetch/terna-static-origin-fetch.sh 'No configured lab resolver returned a public IPv4 address'
require_text host-fetch/terna-static-origin-fetch.sh 'mv -Tf "${next}" "${root}/current"'
require_text host-fetch/terna-static-origin-fetch.sh 'test -s "${bundle}/manifest.json"'
require_text host-fetch/terna-static-origin-fetch.sh '.bundle-v1'
require_text systemd/terna-static-origin-fetch.timer 'OnUnitActiveSec=10min'
require_text systemd/terna-static-origin-fetch.service 'TimeoutStartSec=15min'
require_text systemd/terna-static-origin-fetch.service 'Environment=TERNA_PUBLIC_DNS_RESOLVER=10.10.4.2'
require_text systemd/terna-static-origin-fetch.service 'UMask=0077'
require_text systemd/terna-static-origin-fetch.service 'RuntimeDirectory=terna-static-dr'
require_text systemd/terna-static-origin-fetch.service 'RuntimeDirectoryMode=0750'
require_text systemd/terna-static-origin-fetch.service 'Environment=HOME=/run/terna-static-dr'
require_text systemd/terna-static-origin-fetch.service 'XDG_CACHE_HOME=/run/terna-static-dr'
require_text host-fetch/terna-static-origin-fetch.sh 'install -d -m 0750 /run/terna-static-dr'
require_text host-fetch/terna-static-origin-fetch.sh '/run/terna-static-dr/origin-fetch.lock'
reject_text host-fetch/terna-static-origin-fetch.sh '/run/lock/terna-static-origin-fetch.lock'
runtime_dir_line="$(grep -nF 'install -d -m 0750 /run/terna-static-dr' "${ROOT_DIR}/host-fetch/terna-static-origin-fetch.sh" | cut -d: -f1)"
runtime_lock_line="$(grep -nF 'exec 9>/run/terna-static-dr/origin-fetch.lock' "${ROOT_DIR}/host-fetch/terna-static-origin-fetch.sh" | cut -d: -f1)"
[ "${runtime_dir_line}" -lt "${runtime_lock_line}" ] || {
  echo 'The runtime directory must be created before opening the origin-fetch lock.' >&2
  exit 1
}
require_text bin/lxc-lab-controller.sh '/srv/terna-static-dr/static/current/.bundle-v1'
require_text bin/lxc-lab-controller.sh '/srv/terna-static-dr/static/current/manifest.json'
require_text bin/lxc-lab-controller.sh '/srv/terna-static-dr/static/current/dr/load-chart/index.html'
require_text bin/lxc-lab-controller.sh '.load-chart-v1'
require_text bin/lxc-lab-controller.sh '.load-chart-placeholder-v1'
require_text bin/lxc-lab-controller.sh '/srv/terna-static-dr/static/current/dr/load-chart/data.json'
require_text host-fetch/build-static-bundle.py '/dr/load-chart/index.html'
require_text bin/reconcile-lxc-lab.sh 'install -d -m 2770 -o 65534 -g 101'
require_text bin/reconcile-lxc-lab.sh 'chmod -R g+rX'
require_text bin/reconcile-lxc-lab.sh 'K3S_RESOLV_CONF=/etc/rancher/k3s/resolv.conf'
require_text bin/reconcile-lxc-lab.sh 'nameserver 10.10.2.53'
require_text bin/reconcile-lxc-lab.sh 'delete cronjob terna-static-mirror --ignore-not-found'
require_text bin/reconcile-lxc-lab.sh 'Static bundle is published; starting a fresh Terna static web rollout.'
require_text bin/reconcile-lxc-lab.sh 'the placeholder is valid and DR failover remains available'
require_text bin/reconcile-lxc-lab.sh 'rollout restart deployment/terna-static-web'
snapshot_line="$(grep -nF 'test -s /srv/terna-static-dr/static/current/manifest.json' "${ROOT_DIR}/bin/reconcile-lxc-lab.sh" | tail -n 1 | cut -d: -f1)"
restart_line="$(grep -nF 'rollout restart deployment/terna-static-web' "${ROOT_DIR}/bin/reconcile-lxc-lab.sh" | cut -d: -f1)"
status_line="$(grep -nF 'rollout status deployment/terna-static-web --timeout=180s' "${ROOT_DIR}/bin/reconcile-lxc-lab.sh" | cut -d: -f1)"
[ "${snapshot_line}" -lt "${restart_line}" ] && [ "${restart_line}" -lt "${status_line}" ] || {
  echo 'Static web rollout must start after snapshot publication and before rollout status.' >&2
  exit 1
}
require_text bin/reconcile-lxc-lab.sh "sed -i 's/\\r$//'"
require_text bin/reconcile-lxc-lab.sh "tr -d '\\r[:space:]'"
require_text kubernetes/deployment.yaml 'name: static-web'
require_text kubernetes/ingress.yaml 'host: terna.it'
require_text kubernetes/ingress.yaml 'host: www.terna.it'
require_text ../lxc-lab/setup.sh 'iproute2 iputils-ping dnsutils curl ca-certificates python3'

# BusyBox and GNU mv both need -T here: without it, an existing `current`
# symlink to a directory is followed and the staged link is moved inside it.
publish_test_root="$(mktemp -d)"
cleanup_publish_test() { rm -rf -- "${publish_test_root}"; }
trap cleanup_publish_test EXIT HUP INT TERM
mkdir -p "${publish_test_root}/snapshots/old" "${publish_test_root}/snapshots/new"
if ln -s snapshots/old "${publish_test_root}/current" 2>/dev/null \
  && [ "$(readlink "${publish_test_root}/current" 2>/dev/null || true)" = snapshots/old ]; then
  ln -s snapshots/new "${publish_test_root}/.current.$$"
  mv -Tf "${publish_test_root}/.current.$$" "${publish_test_root}/current"
  [ "$(readlink "${publish_test_root}/current")" = snapshots/new ]
  [ ! -e "${publish_test_root}/snapshots/old/.current.$$" ]
fi
cleanup_publish_test
trap - EXIT HUP INT TERM

echo 'LXC lab architecture contract passed.'
