#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${TERNA_DR_CONFIG_FILE:-${ROOT_DIR}/config.lxc-lab.env}"
[ -r "${CONFIG_FILE}" ] || { echo "Copy config.lxc-lab.env.example to config.lxc-lab.env first." >&2; exit 1; }
# shellcheck disable=SC1090
source "${CONFIG_FILE}"

lxc exec ansible-node -- systemctl stop terna-static-dr-controller.service 2>/dev/null || true
lxc exec ansible-node -- rm -rf /opt/terna-static-dr
lxc exec ansible-node -- install -d -m 0755 /opt/terna-static-dr
lxc exec ansible-node -- install -d -m 0700 /etc/terna-static-dr /var/lib/terna-static-dr
tar -C "${ROOT_DIR}" --exclude='./config.lxc-lab.env' -cf - . | lxc exec ansible-node -- tar -C /opt/terna-static-dr -xf -
lxc file push "${CONFIG_FILE}" ansible-node/etc/terna-static-dr/config.env --mode=0600 --uid=0 --gid=0
lxc exec ansible-node -- install -m 0644 /opt/terna-static-dr/systemd/terna-static-dr-controller.service /etc/systemd/system/terna-static-dr-controller.service
lxc exec ansible-node -- systemctl daemon-reload
if [ "${TERNA_DR_AUTO_FAILOVER_ENABLED:-false}" = true ]; then
  lxc exec ansible-node -- systemctl enable --now terna-static-dr-controller.service
  lxc exec ansible-node -- systemctl is-active --quiet terna-static-dr-controller.service
  echo 'Controller installed and armed inside ansible-node.'
else
  lxc exec ansible-node -- systemctl disable --now terna-static-dr-controller.service 2>/dev/null || true
  echo 'Controller installed inside ansible-node but not armed.'
fi
