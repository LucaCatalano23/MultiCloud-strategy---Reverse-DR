#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/../common/lib.sh"

CONTROL_DIR="/opt/helpdesk-dr"
LXD_SOCKET="/var/snap/lxd/common/lxd/unix.socket"

ensure_container_started "${ANSIBLE_NODE_NAME}"
ensure_container_started "${GIT_SERVER_NAME}"
lxc_retry config set "${ANSIBLE_NODE_NAME}" boot.autostart true

bash "${SCRIPT_DIR}/publish-git-truth.sh"

# Free the socket path before installing or reconciling the LXD client. A
# previous interrupted run may have left the host proxy device configured.
if lxc_retry config device show "${ANSIBLE_NODE_NAME}" | grep -q '^lxd-socket:'; then
  lxc_retry config device remove "${ANSIBLE_NODE_NAME}" lxd-socket
fi

# Auto-riparazione di uno stato dpkg lasciato a meta' da un apt-get interrotto in
# un tentativo precedente: senza, ogni install fallirebbe con "dpkg was
# interrupted" e i retry ripeterebbero lo stesso errore su uno stato rotto.
exec_ansible dpkg --configure -a
exec_ansible apt-get update
exec_ansible env DEBIAN_FRONTEND=noninteractive apt-get install -y ansible-core git ca-certificates curl gzip snapd unzip

lxd_snap_state="$(exec_ansible sh -lc 'if snap list lxd >/dev/null 2>&1; then printf ready; fi')"
if [ "${lxd_snap_state}" != "ready" ]; then
  exec_ansible snap install lxd --channel=5.21/stable
fi

# ansible-node needs only the LXD client. Stop and disable its nested daemon so
# that the host socket proxy can own the canonical Unix-socket path.
exec_ansible snap stop --disable lxd
exec_ansible ln -sfn /snap/bin/lxc /usr/local/bin/lxc
exec_ansible rm -f "${LXD_SOCKET}"
exec_ansible install -d -m 0755 "$(dirname "${LXD_SOCKET}")"

# With bind=instance, LXD creates the listening socket inside ansible-node and
# forwards client requests to the LXD daemon running on the host.
lxc_retry config device add "${ANSIBLE_NODE_NAME}" lxd-socket proxy \
  "listen=unix:${LXD_SOCKET}" \
  "connect=unix:${LXD_SOCKET}" \
  bind=instance \
  uid=0 \
  gid=0 \
  mode=0660

socket_state="$(exec_ansible sh -lc "if [ -S '${LXD_SOCKET}' ]; then printf ready; fi")"
if [ "${socket_state}" != "ready" ]; then
  echo "LXD socket proxy was configured but is not available inside ${ANSIBLE_NODE_NAME}." >&2
  exit 1
fi
exec_ansible lxc list --format compact >/dev/null

exec_ansible install -d -m 0750 /etc/helpdesk-dr
lxc_retry file push "${HELPDESK_DR_CONFIG_PATH}" \
  "${ANSIBLE_NODE_NAME}/etc/helpdesk-dr/config.env" \
  --mode=0600 --uid=0 --gid=0

# Un bootstrap ripetuto sostituisce il clone usato dal processo: fermarlo prima
# evita che una vecchia istanza continui a eseguire file cancellati a meta'.
exec_ansible systemctl stop helpdesk-dr-controller.service 2>/dev/null || true
exec_ansible bash -lc "rm -rf ${CONTROL_DIR} && git clone ${APP_REPOSITORY_URL} ${CONTROL_DIR}"
exec_ansible bash -lc "
  set -euo pipefail
  test -f ${CONTROL_DIR}/ansible/ansible.cfg
  test -f ${CONTROL_DIR}/ansible/inventory.ini
  test -f ${CONTROL_DIR}/ansible/playbooks/failover.yml
  test -f ${CONTROL_DIR}/systemd/helpdesk-dr-controller.service
  test -f ${CONTROL_DIR}/infra/onprem/kustomization.yaml
  test -f ${CONTROL_DIR}/contracts/deployment-contract.json
  cd ${CONTROL_DIR}
  ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook \
    -i ansible/inventory.ini \
    ansible/playbooks/failover.yml \
    --syntax-check
"
exec_ansible chmod 0755 "${CONTROL_DIR}/scripts/poc/helpdesk-dr.sh"
exec_ansible ln -sfn "${CONTROL_DIR}/scripts/poc/helpdesk-dr.sh" /usr/local/bin/helpdesk-dr

# Fail closed: unattended promotion is started only after the operator has
# explicitly armed it and the selected lab/ALB probe passes configuration
# validation. This prevents a missing ALB hostname from looking like an outage.
exec_ansible helpdesk-dr failover/dr-controller validate

# Il controller non deve dipendere da una shell lasciata aperta: systemd lo
# avvia subito, lo riavvia in caso di crash e lo rende attivo a ogni boot del
# coordinatore. Il cutback resta deliberatamente manuale.
exec_ansible install -m 0644 \
  "${CONTROL_DIR}/systemd/helpdesk-dr-controller.service" \
  /etc/systemd/system/helpdesk-dr-controller.service
exec_ansible systemctl daemon-reload
exec_ansible systemctl enable --now helpdesk-dr-controller.service
exec_ansible systemctl is-enabled --quiet helpdesk-dr-controller.service
exec_ansible systemctl is-active --quiet helpdesk-dr-controller.service

exec_ansible bash -lc "cd ${CONTROL_DIR} && git rev-parse --short HEAD && lxc list --format compact >/dev/null"

echo "Ansible control node ready."
echo "Automatic failover controller: active and enabled."
echo "Run scripts from ansible-node, for example:"
echo "  lxc exec ${ANSIBLE_NODE_NAME} -- helpdesk-dr poc/healthcheck"
