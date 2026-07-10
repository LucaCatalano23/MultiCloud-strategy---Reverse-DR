#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

if ! lxc_retry info "${GIT_SERVER_NAME}" >/dev/null 2>&1; then
  echo "Missing git server ${GIT_SERVER_NAME}. Run automazione/lxc-lab/setup.sh first." >&2
  exit 1
fi

exec_git bash -lc "install -d -o \$(id -u gitdaemon) -g \$(id -g gitdaemon) /srv/git"
exec_git bash -lc "test -d /srv/git/${APP_REPOSITORY_NAME} || git init --bare /srv/git/${APP_REPOSITORY_NAME}"

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

cp -R "${ROOT_DIR}/app" "${workdir}/app"
cp -R "${ROOT_DIR}/kubernetes" "${workdir}/kubernetes"
cp -R "${ROOT_DIR}/scripts" "${workdir}/scripts"
cp "${ROOT_DIR}/config.env" "${workdir}/config.env"
cp "${ROOT_DIR}/README.md" "${workdir}/README.md"

git -C "${workdir}" init
git -C "${workdir}" config user.name "Reverse DR Lab"
git -C "${workdir}" config user.email "reverse-dr@example.invalid"
git -C "${workdir}" add .
git -C "${workdir}" commit -m "Publish helpdesk DR source of truth"
git -C "${workdir}" branch -M main
exec_git rm -rf /tmp/helpdesk-dr-publish
exec_git mkdir -p /tmp/helpdesk-dr-publish
tar -C "${workdir}" -cf - . | lxc exec "${GIT_SERVER_NAME}" -- tar -C /tmp/helpdesk-dr-publish -xf -
exec_git bash -lc "
  set -euo pipefail
  git config --global --add safe.directory /tmp/helpdesk-dr-publish
  git config --global --add safe.directory /srv/git/${APP_REPOSITORY_NAME}
  cd /tmp/helpdesk-dr-publish
  git push --force /srv/git/${APP_REPOSITORY_NAME} main
  chown -R \$(id -u gitdaemon):\$(id -g gitdaemon) /srv/git/${APP_REPOSITORY_NAME}
  rm -rf /tmp/helpdesk-dr-publish
"
echo "Published source of truth to ${APP_REPOSITORY_URL}"
