#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/../common/lib.sh"

CONTROL_DIR="/opt/helpdesk-dr"
LXD_SOCKET="/var/snap/lxd/common/lxd/unix.socket"

ensure_container_started "${ANSIBLE_NODE_NAME}"
ensure_container_started "${GIT_SERVER_NAME}"

bash "${SCRIPT_DIR}/publish-git-truth.sh"

if ! lxc_retry config device show "${ANSIBLE_NODE_NAME}" | grep -q '^lxd-socket:'; then
  lxc_retry config device add "${ANSIBLE_NODE_NAME}" lxd-socket proxy \
    "listen=unix:${LXD_SOCKET}" \
    "connect=unix:${LXD_SOCKET}" \
    bind=container \
    uid=0 \
    gid=0 \
    mode=0660
fi

exec_ansible bash -lc "install -d /var/snap/lxd/common/lxd"
exec_ansible apt-get update
exec_ansible env DEBIAN_FRONTEND=noninteractive apt-get install -y ansible-core awscli git ca-certificates curl gzip snapd

localstack_url="$(discover_localstack_endpoint exec_ansible)"
exec_ansible install -d -m 0750 /etc/helpdesk-dr
exec_ansible bash -lc "printf '%s\\n' '${localstack_url}' >/etc/helpdesk-dr/localstack.endpoint && chmod 0600 /etc/helpdesk-dr/localstack.endpoint"

if ! exec_ansible sh -lc "command -v lxc >/dev/null 2>&1"; then
  exec_ansible snap install lxd --channel=5.21/stable
fi

exec_ansible bash -lc "rm -rf ${CONTROL_DIR} && git clone ${APP_REPOSITORY_URL} ${CONTROL_DIR}"
exec_ansible bash -lc "cat >/usr/local/bin/helpdesk-dr <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
script_path=\"\${1:-}\"
if [ -z \"\${script_path}\" ]; then
  echo "Usage: helpdesk-dr <category/script-without-.sh> [args...]" >&2
  echo "Example: helpdesk-dr poc/healthcheck" >&2
  exit 1
fi
case \"\${script_path}\" in
  */../*|../*|/*|*.sh)
    echo "Invalid script path: \${script_path}" >&2
    exit 1
    ;;
esac
shift
cd ${CONTROL_DIR}
exec bash \"scripts/\${script_path}.sh\" \"\$@\"
EOF
chmod +x /usr/local/bin/helpdesk-dr"

exec_ansible bash -lc "cd ${CONTROL_DIR} && git rev-parse --short HEAD && lxc list --format compact >/dev/null"
exec_ansible helpdesk-dr backup/install-ansible-backup-mirror-timer

echo "Ansible control node ready."
echo "Run scripts from ansible-node, for example:"
echo "  lxc exec ${ANSIBLE_NODE_NAME} -- helpdesk-dr poc/healthcheck"
