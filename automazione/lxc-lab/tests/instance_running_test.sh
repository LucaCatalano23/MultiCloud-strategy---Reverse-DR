#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
setup_file="${ROOT_DIR}/setup.sh"

if grep -Fq 'Status: Running' "${setup_file}"; then
  echo 'setup.sh still relies on localized human-readable LXC status output.' >&2
  exit 1
fi
grep -Fq 'instance_running()' "${setup_file}"
grep -Fq 'lxc_retry list "$1" -c s --format csv' "${setup_file}"
grep -Fq '99-lxc-lab-ipv4-only.conf' "${setup_file}"
grep -Fq 'net.ipv6.conf.all.disable_ipv6 = 1' "${setup_file}"

echo 'Instance running detection contract passed.'
