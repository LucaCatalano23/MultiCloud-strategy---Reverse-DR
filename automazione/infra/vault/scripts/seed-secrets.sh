#!/usr/bin/env bash
# Popola OpenBao con i segreti del sito DR.
#
# Sostituisce la creazione diretta di Secret Kubernetes: da qui in poi l'unica
# fonte di verita' del sito DR e' il vault, e i Secret nel cluster sono
# materializzati da External Secrets Operator. Lo stesso contratto del sito
# primario, dove la fonte e' AWS Secrets Manager.
#
# Legge i valori dall'ambiente, come faceva `create-secrets.sh`: nessun valore
# reale entra nel repository. Il token amministrativo non compare mai in argv
# (finirebbe nella process list): viaggia in un file di configurazione curl con
# permessi 600.
set -euo pipefail

BAO_ADDR="${BAO_ADDR:-https://vault.azienda.lan:8200}"
BAO_CACERT="${BAO_CACERT:-}"
KV_MOUNT="${OPENBAO_KV_MOUNT:-helios}"

: "${BAO_TOKEN:?BAO_TOKEN (token amministrativo OpenBao) must be set}"

require_value() {
  local name="$1"
  if [ -z "${!name:-}" ]; then
    echo "Required environment variable ${name} is not set." >&2
    return 1
  fi
}

require_file() {
  local name="$1"
  require_value "${name}"
  if [ ! -r "${!name}" ]; then
    echo "${name} does not point to a readable file." >&2
    return 1
  fi
}

require_min_length() {
  local name="$1" minimum="$2" value="${!1}"
  if [ "${#value}" -lt "${minimum}" ]; then
    echo "${name} must contain at least ${minimum} characters." >&2
    return 1
  fi
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

# Il costruttore di payload legge da os.environ: ogni variabile che vi compare
# deve essere esportata, comprese quelle a cui questo script assegna un default
# (un'assegnazione semplice non esporta, e Python fallirebbe con KeyError).
export KEYCLOAK_DB_NAME KEYCLOAK_DB_USERNAME KEYCLOAK_DB_PASSWORD
export KEYCLOAK_ADMIN_USERNAME KEYCLOAK_ADMIN_PASSWORD
export HELIOS_BFF_CLIENT_SECRET HELIOS_SESSION_ENCRYPTION_KEY HELIOS_DATABASE_URL
export HELIOS_DR_OPERATOR_USERNAME HELIOS_DR_OPERATOR_PASSWORD
export HELIOS_DR_OPERATOR_EMPLOYEE_ID HELIOS_DR_OPERATOR_EMAIL

require_min_length KEYCLOAK_DB_PASSWORD 16
require_min_length KEYCLOAK_ADMIN_PASSWORD 16
require_min_length HELIOS_BFF_CLIENT_SECRET 32
require_min_length HELIOS_DR_OPERATOR_PASSWORD 16

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

# La guardia sul database legacy resta valida anche con OpenBao: il vincolo e'
# sullo schema del database, non su dove e' custodita la credenziale.
# Vedi CLAUDE.md §1 e infra/onprem/scripts/apply-migrations.sh.
helios_db_name="${HELIOS_DATABASE_URL##*/}"
helios_db_name="${helios_db_name%%\?*}"
if [ "${helios_db_name}" = "helpdesk" ]; then
  echo "HELIOS_DATABASE_URL non deve puntare al database legacy 'helpdesk': usa un database dedicato (es. .../helios)." >&2
  exit 1
fi

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

for variable in \
  HELIOS_APP_TLS_CERT_FILE \
  HELIOS_APP_TLS_KEY_FILE \
  HELIOS_IDENTITY_TLS_CERT_FILE \
  HELIOS_IDENTITY_TLS_KEY_FILE; do
  require_file "${variable}"
done

umask 077
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/helios-openbao-seed.XXXXXX")"
trap 'rm -rf "${work_dir}"' EXIT

# Il token viaggia in un file di configurazione curl, mai in argv.
printf 'header = "X-Vault-Token: %s"\n' "${BAO_TOKEN}" >"${work_dir}/curl.conf"
if [ -n "${BAO_CACERT}" ]; then
  printf 'cacert = "%s"\n' "${BAO_CACERT}" >>"${work_dir}/curl.conf"
fi

write_secret() {
  local path="$1" payload="$2"
  local response
  response="$(curl --silent --show-error --fail \
    --config "${work_dir}/curl.conf" \
    --header 'content-type: application/json' \
    --request POST \
    --data "@${payload}" \
    "${BAO_ADDR}/v1/${KV_MOUNT}/data/${path}")" || {
    echo "Scrittura fallita su ${KV_MOUNT}/${path}." >&2
    return 1
  }
  echo "  scritto ${KV_MOUNT}/${path}"
}

# I payload sono costruiti da Python e non da printf: i valori possono contenere
# virgolette, backslash o newline (una chiave privata TLS li contiene sempre) e
# una concatenazione manuale produrrebbe JSON non valido o, peggio, troncato.
build_payload() {
  local target="$1"
  shift
  # Le specifiche passano una per riga, non separate da spazi: un percorso di
  # certificato puo' contenere spazi e uno split su whitespace lo spezzerebbe.
  BUILD_KEYS="$(printf '%s\n' "$@")" python3 - "${target}" <<'PY'
import json
import os
import sys

target = sys.argv[1]
data = {}
for spec in os.environ["BUILD_KEYS"].splitlines():
    if not spec:
        continue
    key, source = spec.split("=", 1)
    if source.startswith("@"):
        with open(source[1:], "r", encoding="utf-8") as handle:
            data[key] = handle.read()
    else:
        data[key] = os.environ[source]

with open(target, "w", encoding="utf-8") as handle:
    json.dump({"data": data}, handle)
PY
}

echo "Scrittura segreti applicativi in ${BAO_ADDR}..."

build_payload "${work_dir}/app-database.json" "DATABASE_URL=HELIOS_DATABASE_URL"
write_secret "onprem/application/database" "${work_dir}/app-database.json"

build_payload "${work_dir}/app-bff-runtime.json" \
  "OIDC_CLIENT_SECRET=HELIOS_BFF_CLIENT_SECRET" \
  "SESSION_ENCRYPTION_KEY=HELIOS_SESSION_ENCRYPTION_KEY"
write_secret "onprem/application/bff-runtime" "${work_dir}/app-bff-runtime.json"

build_payload "${work_dir}/app-tls.json" \
  "tls.crt=@${HELIOS_APP_TLS_CERT_FILE}" \
  "tls.key=@${HELIOS_APP_TLS_KEY_FILE}"
write_secret "onprem/application/tls" "${work_dir}/app-tls.json"

echo "Scrittura segreti identita'..."

build_payload "${work_dir}/keycloak-postgres.json" \
  "POSTGRES_DB=KEYCLOAK_DB_NAME" \
  "POSTGRES_USER=KEYCLOAK_DB_USERNAME" \
  "POSTGRES_PASSWORD=KEYCLOAK_DB_PASSWORD"
write_secret "onprem/identity/keycloak-postgres" "${work_dir}/keycloak-postgres.json"

build_payload "${work_dir}/keycloak-admin.json" \
  "username=KEYCLOAK_ADMIN_USERNAME" \
  "password=KEYCLOAK_ADMIN_PASSWORD"
write_secret "onprem/identity/keycloak-bootstrap-admin" "${work_dir}/keycloak-admin.json"

build_payload "${work_dir}/bff-oidc.json" "OIDC_CLIENT_SECRET=HELIOS_BFF_CLIENT_SECRET"
write_secret "onprem/identity/bff-oidc" "${work_dir}/bff-oidc.json"

build_payload "${work_dir}/dr-operator.json" \
  "username=HELIOS_DR_OPERATOR_USERNAME" \
  "password=HELIOS_DR_OPERATOR_PASSWORD" \
  "employee_id=HELIOS_DR_OPERATOR_EMPLOYEE_ID" \
  "email=HELIOS_DR_OPERATOR_EMAIL"
write_secret "onprem/identity/dr-operator" "${work_dir}/dr-operator.json"

build_payload "${work_dir}/identity-tls.json" \
  "tls.crt=@${HELIOS_IDENTITY_TLS_CERT_FILE}" \
  "tls.key=@${HELIOS_IDENTITY_TLS_KEY_FILE}"
write_secret "onprem/identity/tls" "${work_dir}/identity-tls.json"

echo "Segreti del sito DR scritti in OpenBao. Nessun valore e' entrato nel repository."
