#!/usr/bin/env bash
set -euo pipefail
set +x

KCADM=/opt/keycloak/bin/kcadm.sh
REALM=helios-desk
API_CLIENT=helios-api
SERVER_URL=http://keycloak.helios-identity.svc.cluster.local:8080

for variable in \
  KEYCLOAK_ADMIN_USERNAME \
  KEYCLOAK_ADMIN_PASSWORD \
  HELIOS_DR_OPERATOR_USERNAME \
  HELIOS_DR_OPERATOR_PASSWORD \
  HELIOS_DR_OPERATOR_EMPLOYEE_ID \
  HELIOS_DR_OPERATOR_EMAIL; do
  if [ -z "${!variable:-}" ]; then
    echo "Provisioning input ${variable} is missing." >&2
    exit 1
  fi
done

if ! [[ "${HELIOS_DR_OPERATOR_USERNAME}" =~ ^[A-Za-z0-9._-]{3,64}$ ]]; then
  echo "Operator username contains unsupported characters." >&2
  exit 1
fi
if ! [[ "${HELIOS_DR_OPERATOR_EMPLOYEE_ID}" =~ ^[A-Za-z0-9._-]{1,128}$ ]]; then
  echo "Operator employee ID contains unsupported characters." >&2
  exit 1
fi
if ! [[ "${HELIOS_DR_OPERATOR_EMAIL}" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
  echo "Operator email is invalid." >&2
  exit 1
fi

umask 077
config_file="$(mktemp /tmp/helios-kcadm.XXXXXX)"
trap 'rm -f "${config_file}"' EXIT

"${KCADM}" config credentials \
  --config "${config_file}" \
  --server "${SERVER_URL}" \
  --realm master \
  --user "${KEYCLOAK_ADMIN_USERNAME}" \
  --password "${KEYCLOAK_ADMIN_PASSWORD}" >/dev/null

user_document="$(
  "${KCADM}" get users \
    --config "${config_file}" \
    -r "${REALM}" \
    -q exact=true \
    -q "username=${HELIOS_DR_OPERATOR_USERNAME}" \
    --fields id
)"
user_id="$(printf '%s\n' "${user_document}" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"

if [ -z "${user_id}" ]; then
  user_id="$(
    "${KCADM}" create users \
      --config "${config_file}" \
      -r "${REALM}" \
      -s "username=${HELIOS_DR_OPERATOR_USERNAME}" \
      -s enabled=true \
      -s emailVerified=true \
      -s "email=${HELIOS_DR_OPERATOR_EMAIL}" \
      -s "attributes.employee_id=[\"${HELIOS_DR_OPERATOR_EMPLOYEE_ID}\"]" \
      -i
  )"
else
  "${KCADM}" update "users/${user_id}" \
    --config "${config_file}" \
    -r "${REALM}" \
    -s enabled=true \
    -s emailVerified=true \
    -s "email=${HELIOS_DR_OPERATOR_EMAIL}" \
    -s "attributes.employee_id=[\"${HELIOS_DR_OPERATOR_EMPLOYEE_ID}\"]" >/dev/null
fi

if ! [[ "${user_id}" =~ ^[0-9a-fA-F-]{36}$ ]]; then
  echo "Keycloak returned an invalid operator user identifier." >&2
  exit 1
fi

"${KCADM}" set-password \
  --config "${config_file}" \
  -r "${REALM}" \
  --userid "${user_id}" \
  --new-password "${HELIOS_DR_OPERATOR_PASSWORD}" \
  --temporary >/dev/null

"${KCADM}" add-roles \
  --config "${config_file}" \
  -r "${REALM}" \
  --uid "${user_id}" \
  --cclientid "${API_CLIENT}" \
  --rolename tickets.read \
  --rolename tickets.write \
  --rolename automation.execute >/dev/null

echo "DR operator reconciled with the required Helios permissions; password change is required at first login."
