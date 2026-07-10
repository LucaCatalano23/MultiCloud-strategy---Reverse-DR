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

ensure_container_started "${ANSIBLE_NODE_NAME}"
exec_ansible helpdesk-dr "${script_name}" "$@"
