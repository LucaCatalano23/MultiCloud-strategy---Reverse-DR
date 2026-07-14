#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/../common/lib.sh"

script_name="${1:-}"
if [ -z "${script_name}" ]; then
  echo "Usage: $0 <category/script-without-.sh> [args...]" >&2
  echo "Example: $0 poc/healthcheck" >&2
  echo "Example: $0 backup/backup-cloud" >&2
  echo "Example: $0 failover/failover-to-onprem" >&2
  exit 1
fi
shift || true

case "${script_name}" in
  */../*|../*|/*|*.sh)
    echo "Invalid script path: ${script_name}" >&2
    exit 1
    ;;
esac

ensure_onprem_network_started
ensure_container_started "${ANSIBLE_NODE_NAME}"
control_node_status="$(lxc_retry exec "${ANSIBLE_NODE_NAME}" -- sh -lc '
  missing=""
  [ -x /usr/local/bin/helpdesk-dr ] || missing="${missing} /usr/local/bin/helpdesk-dr"
  [ -d /opt/helpdesk-dr/.git ] || missing="${missing} /opt/helpdesk-dr/.git"
  [ -f /opt/helpdesk-dr/ansible/playbooks/failover.yml ] || missing="${missing} /opt/helpdesk-dr/ansible/playbooks/failover.yml"
  if [ -z "${missing}" ]; then
    printf ready
  else
    printf "missing:%s" "${missing}"
  fi
')"
if [ "${control_node_status}" != "ready" ]; then
  cat >&2 <<EOF
The Ansible control node is running, but its bootstrap is incomplete or outdated.
Readiness details: ${control_node_status}
From ${ROOT_DIR}, run:
  bash scripts/poc/bootstrap-ansible-control-node.sh

Then retry:
  bash scripts/poc/ansible-run.sh ${script_name}
EOF
  exit 1
fi

# Do not retry application-level failures: DR and restore commands can mutate
# state and must never be executed twice by an infrastructure retry wrapper.
exec_ansible_once helpdesk-dr "${script_name}" "$@"
