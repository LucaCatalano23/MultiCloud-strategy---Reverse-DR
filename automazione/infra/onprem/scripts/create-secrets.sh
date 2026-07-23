#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ONPREM_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
KUBECTL_BIN="${KUBECTL:-kubectl}"

require_value() {
  local name="$1"
  if [ -z "${!name:-}" ]; then
    echo "Required environment variable ${name} is not set." >&2
    return 1
  fi
}

require_file() {
  local name="$1"
  local path="${!name:-}"
  require_value "${name}"
  if [ ! -r "${path}" ]; then
    echo "${name} does not point to a readable file." >&2
    return 1
  fi
}

require_min_length() {
  local name="$1"
  local minimum="$2"
  local value="${!name}"
  if [ "${#value}" -lt "${minimum}" ]; then
    echo "${name} must contain at least ${minimum} characters." >&2
    return 1
  fi
}

apply_generic_secret() {
  local namespace="$1"
  local name="$2"
  local directory="$3"
  shift 3

  local args=()
  local key
  for key in "$@"; do
    args+=("--from-file=${key}=${directory}/${key}")
  done

  "${KUBECTL_BIN}" -n "${namespace}" create secret generic "${name}" \
    "${args[@]}" \
    --dry-run=client \
    --output=yaml | "${KUBECTL_BIN}" apply -f - >/dev/null
}

for variable in \
  KEYCLOAK_DB_PASSWORD \
  KEYCLOAK_ADMIN_USERNAME \
  KEYCLOAK_ADMIN_PASSWORD \
  HELIOS_BFF_CLIENT_SECRET \
  HELIOS_SESSION_ENCRYPTION_KEY \
  HELIOS_DATABASE_URL \
  HELIOS_DR_OPERATOR_USERNAME \
  HELIOS_DR_OPERATOR_PASSWORD \
  HELIOS_DR_OPERATOR_EMPLOYEE_ID \
  HELIOS_DR_OPERATOR_EMAIL; do
  require_value "${variable}"
done

KEYCLOAK_DB_NAME="${KEYCLOAK_DB_NAME:-keycloak}"
KEYCLOAK_DB_USERNAME="${KEYCLOAK_DB_USERNAME:-keycloak}"

require_min_length KEYCLOAK_DB_PASSWORD 16
require_min_length KEYCLOAK_ADMIN_PASSWORD 16
require_min_length HELIOS_BFF_CLIENT_SECRET 32
require_min_length HELIOS_DR_OPERATOR_PASSWORD 16
export HELIOS_SESSION_ENCRYPTION_KEY

if ! [[ "${HELIOS_DR_OPERATOR_USERNAME}" =~ ^[A-Za-z0-9._-]{3,64}$ ]]; then
  echo "HELIOS_DR_OPERATOR_USERNAME contains unsupported characters." >&2
  exit 1
fi
if ! [[ "${HELIOS_DR_OPERATOR_EMPLOYEE_ID}" =~ ^[A-Za-z0-9._-]{1,128}$ ]]; then
  echo "HELIOS_DR_OPERATOR_EMPLOYEE_ID contains unsupported characters." >&2
  exit 1
fi
if ! [[ "${HELIOS_DR_OPERATOR_EMAIL}" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
  echo "HELIOS_DR_OPERATOR_EMAIL is not a valid email address." >&2
  exit 1
fi

case "${HELIOS_DATABASE_URL}" in
  postgresql://*|postgresql+asyncpg://*) ;;
  *)
    echo "HELIOS_DATABASE_URL must be a PostgreSQL URL." >&2
    exit 1
    ;;
esac

python3 - <<'PY'
import base64
import os

value = os.environ["HELIOS_SESSION_ENCRYPTION_KEY"]
try:
    decoded = base64.urlsafe_b64decode(value.encode("ascii"))
except Exception as error:
    raise SystemExit("HELIOS_SESSION_ENCRYPTION_KEY is not URL-safe base64") from error
if len(decoded) != 32:
    raise SystemExit("HELIOS_SESSION_ENCRYPTION_KEY must be a Fernet key encoding 32 bytes")
PY

HELIOS_APP_TLS_CERT_FILE="${HELIOS_APP_TLS_CERT_FILE:-${HELIOS_TLS_CERT_FILE:-}}"
HELIOS_APP_TLS_KEY_FILE="${HELIOS_APP_TLS_KEY_FILE:-${HELIOS_TLS_KEY_FILE:-}}"
HELIOS_IDENTITY_TLS_CERT_FILE="${HELIOS_IDENTITY_TLS_CERT_FILE:-${HELIOS_TLS_CERT_FILE:-}}"
HELIOS_IDENTITY_TLS_KEY_FILE="${HELIOS_IDENTITY_TLS_KEY_FILE:-${HELIOS_TLS_KEY_FILE:-}}"
export HELIOS_APP_TLS_CERT_FILE HELIOS_APP_TLS_KEY_FILE
export HELIOS_IDENTITY_TLS_CERT_FILE HELIOS_IDENTITY_TLS_KEY_FILE

for variable in \
  HELIOS_APP_TLS_CERT_FILE \
  HELIOS_APP_TLS_KEY_FILE \
  HELIOS_IDENTITY_TLS_CERT_FILE \
  HELIOS_IDENTITY_TLS_KEY_FILE; do
  require_file "${variable}"
done

"${KUBECTL_BIN}" apply -f "${ONPREM_DIR}/namespaces.yaml" >/dev/null

umask 077
secret_dir="$(mktemp -d "${TMPDIR:-/tmp}/helios-onprem-secrets.XXXXXX")"
trap 'rm -rf "${secret_dir}"' EXIT

mkdir -p \
  "${secret_dir}/keycloak-postgres" \
  "${secret_dir}/keycloak-bootstrap-admin" \
  "${secret_dir}/identity-bff-oidc" \
  "${secret_dir}/identity-dr-operator" \
  "${secret_dir}/app-bff-runtime" \
  "${secret_dir}/app-database"

printf '%s' "${KEYCLOAK_DB_NAME}" >"${secret_dir}/keycloak-postgres/POSTGRES_DB"
printf '%s' "${KEYCLOAK_DB_USERNAME}" >"${secret_dir}/keycloak-postgres/POSTGRES_USER"
printf '%s' "${KEYCLOAK_DB_PASSWORD}" >"${secret_dir}/keycloak-postgres/POSTGRES_PASSWORD"
printf '%s' "${KEYCLOAK_ADMIN_USERNAME}" >"${secret_dir}/keycloak-bootstrap-admin/username"
printf '%s' "${KEYCLOAK_ADMIN_PASSWORD}" >"${secret_dir}/keycloak-bootstrap-admin/password"
printf '%s' "${HELIOS_BFF_CLIENT_SECRET}" >"${secret_dir}/identity-bff-oidc/OIDC_CLIENT_SECRET"
printf '%s' "${HELIOS_DR_OPERATOR_USERNAME}" >"${secret_dir}/identity-dr-operator/username"
printf '%s' "${HELIOS_DR_OPERATOR_PASSWORD}" >"${secret_dir}/identity-dr-operator/password"
printf '%s' "${HELIOS_DR_OPERATOR_EMPLOYEE_ID}" >"${secret_dir}/identity-dr-operator/employee_id"
printf '%s' "${HELIOS_DR_OPERATOR_EMAIL}" >"${secret_dir}/identity-dr-operator/email"
printf '%s' "${HELIOS_BFF_CLIENT_SECRET}" >"${secret_dir}/app-bff-runtime/OIDC_CLIENT_SECRET"
printf '%s' "${HELIOS_SESSION_ENCRYPTION_KEY}" >"${secret_dir}/app-bff-runtime/SESSION_ENCRYPTION_KEY"
printf '%s' "${HELIOS_DATABASE_URL}" >"${secret_dir}/app-database/DATABASE_URL"

apply_generic_secret \
  helios-identity \
  keycloak-postgres \
  "${secret_dir}/keycloak-postgres" \
  POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD
apply_generic_secret \
  helios-identity \
  keycloak-bootstrap-admin \
  "${secret_dir}/keycloak-bootstrap-admin" \
  username password
apply_generic_secret \
  helios-identity \
  helios-bff-oidc \
  "${secret_dir}/identity-bff-oidc" \
  OIDC_CLIENT_SECRET
apply_generic_secret \
  helios-identity \
  helios-dr-operator \
  "${secret_dir}/identity-dr-operator" \
  username password employee_id email
apply_generic_secret \
  helios-desk \
  helios-bff-runtime \
  "${secret_dir}/app-bff-runtime" \
  OIDC_CLIENT_SECRET SESSION_ENCRYPTION_KEY
apply_generic_secret \
  helios-desk \
  helios-app-database \
  "${secret_dir}/app-database" \
  DATABASE_URL

"${KUBECTL_BIN}" -n helios-desk create secret tls helios-app-tls \
  --cert="${HELIOS_APP_TLS_CERT_FILE}" \
  --key="${HELIOS_APP_TLS_KEY_FILE}" \
  --dry-run=client \
  --output=yaml | "${KUBECTL_BIN}" apply -f - >/dev/null
"${KUBECTL_BIN}" -n helios-identity create secret tls helios-identity-tls \
  --cert="${HELIOS_IDENTITY_TLS_CERT_FILE}" \
  --key="${HELIOS_IDENTITY_TLS_KEY_FILE}" \
  --dry-run=client \
  --output=yaml | "${KUBECTL_BIN}" apply -f - >/dev/null

echo "On-prem identity and application secrets reconciled without writing values to the repository."
