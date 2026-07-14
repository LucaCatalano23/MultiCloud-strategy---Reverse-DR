#!/usr/bin/env bash
set -euo pipefail

control_dir="${HELPDESK_DR_CONTROL_DIR:-/opt/helpdesk-dr}"
script_path="${1:-}"

if [ -z "${script_path}" ]; then
  echo "Usage: helpdesk-dr <category/script-without-.sh> [args...]" >&2
  echo "Example: helpdesk-dr poc/healthcheck" >&2
  exit 1
fi

case "${script_path}" in
  ..|../*|*/..|*/../*|/*|*.sh)
    echo "Invalid script path: ${script_path}" >&2
    exit 1
    ;;
esac

target="${control_dir}/scripts/${script_path}.sh"
if [ ! -f "${target}" ]; then
  echo "Unknown helpdesk-dr command: ${script_path}" >&2
  exit 1
fi

shift
cd "${control_dir}"
exec bash "${target}" "$@"
