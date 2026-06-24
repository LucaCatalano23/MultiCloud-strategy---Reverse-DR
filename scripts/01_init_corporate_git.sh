#!/usr/bin/env bash
set -Eeuo pipefail

GITEA_URL="${GITEA_URL:-http://gitea:3000}"
GITEA_USER="${GITEA_ADMIN_USER:?GITEA_ADMIN_USER non definita}"
GITEA_PASSWORD="${GITEA_ADMIN_PASSWORD:?GITEA_ADMIN_PASSWORD non definita}"
REPOSITORY="${GITEA_REPOSITORY:-reverse-dr-poc}"

for _ in $(seq 1 30); do
  curl --fail --silent "${GITEA_URL}/api/healthz" >/dev/null && break
  sleep 2
done

http_code="$(curl --silent --output /tmp/gitea-create.json --write-out '%{http_code}' \
  --user "${GITEA_USER}:${GITEA_PASSWORD}" \
  --header 'Content-Type: application/json' \
  --data "{\"name\":\"${REPOSITORY}\",\"private\":true}" \
  "${GITEA_URL}/api/v1/user/repos")"
if [[ "${http_code}" != "201" && "${http_code}" != "409" ]]; then
  cat /tmp/gitea-create.json >&2
  exit 1
fi

git config user.name "${GIT_AUTHOR_NAME:-Reverse DR Automation}"
git config user.email "${GIT_AUTHOR_EMAIL:-reverse-dr@example.invalid}"
git init
git add .
git diff --cached --quiet || git commit -m "Bootstrap Reverse DR PoC"
git remote remove sovereign 2>/dev/null || true
git remote add sovereign "http://gitea:3000/${GITEA_USER}/${REPOSITORY}.git"
basic_auth="$(printf '%s:%s' "${GITEA_USER}" "${GITEA_PASSWORD}" | base64 --wrap=0)"
git -c "http.extraHeader=Authorization: Basic ${basic_auth}" \
  push --set-upstream sovereign HEAD:main
unset basic_auth

echo "Codice pubblicato nel repository sovrano ${GITEA_USER}/${REPOSITORY}."
