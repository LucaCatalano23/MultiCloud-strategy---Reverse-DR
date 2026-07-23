#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/../common/lib.sh"

command -v docker >/dev/null 2>&1 || {
  echo "Docker is required to build the Helpdesk application image." >&2
  exit 1
}

image="reverse-dr/helpdesk-api:local"
archive="${ROOT_DIR}/.state/helpdesk-api-image.tar"
mkdir -p "$(dirname "${archive}")"

docker build --pull -t "${image}" "${ROOT_DIR}/app"
docker save "${image}" -o "${archive}"

imported_targets=()
for target in "${CLOUD_K3S_NAME}" "${ONPREM_K3S_NAME}"; do
  if ! container_exists "${target}"; then
    echo "Skipping ${target}: instance does not exist (not provisioned in this environment)." >&2
    continue
  fi
  ensure_container_started "${target}"
  lxc_retry file push "${archive}" "${target}/tmp/helpdesk-api-image.tar"
  lxc_retry exec "${target}" -- k3s ctr images import /tmp/helpdesk-api-image.tar
  lxc_retry exec "${target}" -- rm -f /tmp/helpdesk-api-image.tar
  imported_targets+=("${target}")
done

rm -f "${archive}"
if [ "${#imported_targets[@]}" -eq 0 ]; then
  echo "No k3s target was available; image was not imported anywhere." >&2
  exit 1
fi
echo "Immutable Helpdesk image imported into: ${imported_targets[*]}."

