#!/usr/bin/env bash
set -Eeuo pipefail
set +x

KCADM=/opt/keycloak/bin/kcadm.sh
REALM=helios-desk
API_CLIENT=helios-api
BFF_CLIENT=helios-bff
ROLES_SCOPE=roles
SERVER_URL=http://keycloak.helios-identity.svc.cluster.local:8080
REQUIRED_ROLES=(tickets.read tickets.write automation.execute)
CURRENT_STEP=initialization

report_error() {
  local status=$?
  echo "Provisioning failed during '${CURRENT_STEP}' (exit ${status})." >&2
  return "${status}"
}

trap report_error ERR

set_step() {
  CURRENT_STEP="$1"
  echo "Provisioning step: ${CURRENT_STEP}" >&2
}

object_ids_from_csv() {
  local document="$1"
  local expected="$2"
  local left right remainder

  while IFS=, read -r left right remainder; do
    left="${left%$'\r'}"
    right="${right%$'\r'}"
    if [ -n "${remainder}" ]; then
      continue
    fi
    if [ "${right}" = "${expected}" ] && [[ "${left}" =~ ^[0-9a-fA-F-]{36}$ ]]; then
      printf '%s\n' "${left}"
    elif [ "${left}" = "${expected}" ] && [[ "${right}" =~ ^[0-9a-fA-F-]{36}$ ]]; then
      printf '%s\n' "${right}"
    fi
  done <<<"${document}"
}

require_single_object_id() {
  local description="$1"
  local document="$2"
  local expected="$3"
  local ids first second

  ids="$(object_ids_from_csv "${document}" "${expected}")"
  first="$(printf '%s\n' "${ids}" | sed -n '1p')"
  second="$(printf '%s\n' "${ids}" | sed -n '2p')"
  if [ -z "${first}" ] || [ -n "${second}" ]; then
    echo "Expected exactly one ${description}." >&2
    exit 1
  fi
  printf '%s\n' "${first}"
}

optional_single_object_id() {
  local description="$1"
  local document="$2"
  local expected="$3"
  local ids first second

  ids="$(object_ids_from_csv "${document}" "${expected}")"
  first="$(printf '%s\n' "${ids}" | sed -n '1p')"
  second="$(printf '%s\n' "${ids}" | sed -n '2p')"
  if [ -n "${second}" ]; then
    echo "Expected at most one ${description}." >&2
    exit 1
  fi
  printf '%s\n' "${first}"
}

require_uuid() {
  local description="$1"
  local value="$2"

  if ! [[ "${value}" =~ ^[0-9a-fA-F-]{36}$ ]]; then
    echo "Keycloak returned an invalid ${description} identifier." >&2
    exit 1
  fi
}

require_roles_in_document() {
  local description="$1"
  local document="$2"
  local role

  for role in "${REQUIRED_ROLES[@]}"; do
    if ! printf '%s\n' "${document}" | grep -Fq "\"${role}\""; then
      echo "${description} is missing required role ${role}." >&2
      exit 1
    fi
  done
}

top_level_roles_claim() {
  sed -n '
    /^  "roles"[[:space:]]*:/ {
      :capture
      p
      /]/q
      n
      b capture
    }
  '
}

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
mapper_file="$(mktemp /tmp/helios-roles-mapper.XXXXXX)"
mapper_update_file="$(mktemp /tmp/helios-roles-mapper-update.XXXXXX)"
scope_roles_file="$(mktemp /tmp/helios-scope-roles.XXXXXX)"
trap 'rm -f "${config_file}" "${mapper_file}" "${mapper_update_file}" "${scope_roles_file}"' EXIT

set_step "authenticating the Keycloak administrator"
"${KCADM}" config credentials \
  --config "${config_file}" \
  --server "${SERVER_URL}" \
  --realm master \
  --user "${KEYCLOAK_ADMIN_USERNAME}" \
  --password "${KEYCLOAK_ADMIN_PASSWORD}" >/dev/null

set_step "resolving helios-bff and helios-api clients"
clients_document="$(
  "${KCADM}" get clients \
    --config "${config_file}" \
    -r "${REALM}" \
    --fields id,clientId \
    --format csv \
    --noquotes
)"
bff_client_id="$(
  require_single_object_id "${BFF_CLIENT} client" \
    "${clients_document}" "${BFF_CLIENT}"
)"
api_client_id="$(
  require_single_object_id "${API_CLIENT} client" \
    "${clients_document}" "${API_CLIENT}"
)"
require_uuid "${BFF_CLIENT} client" "${bff_client_id}"
require_uuid "${API_CLIENT} client" "${api_client_id}"

set_step "resolving the roles client scope"
client_scopes_document="$(
  "${KCADM}" get client-scopes \
    --config "${config_file}" \
    -r "${REALM}" \
    --fields id,name \
    --format csv \
    --noquotes
)"
roles_scope_id="$(
  require_single_object_id "${ROLES_SCOPE} client scope" \
    "${client_scopes_document}" "${ROLES_SCOPE}"
)"
require_uuid "${ROLES_SCOPE} client scope" "${roles_scope_id}"

# Keep least privilege enabled and repair relations that startup realm import
# cannot update once the realm already exists.
set_step "enforcing least-privilege on helios-bff"
"${KCADM}" update "clients/${bff_client_id}" \
  --config "${config_file}" \
  -r "${REALM}" \
  -s fullScopeAllowed=false >/dev/null

set_step "attaching the roles scope to helios-bff"
default_scopes_document="$(
  "${KCADM}" get "clients/${bff_client_id}/default-client-scopes" \
    --config "${config_file}" \
    -r "${REALM}" \
    --fields id,name \
    --format csv \
    --noquotes
)"
attached_roles_scope_id="$(
  optional_single_object_id "attached ${ROLES_SCOPE} client scope" \
    "${default_scopes_document}" "${ROLES_SCOPE}"
)"
if [ -z "${attached_roles_scope_id}" ]; then
  "${KCADM}" update \
    "clients/${bff_client_id}/default-client-scopes/${roles_scope_id}" \
    --config "${config_file}" \
    -r "${REALM}" >/dev/null
elif [ "${attached_roles_scope_id}" != "${roles_scope_id}" ]; then
  echo "The attached roles client scope has an unexpected identifier." >&2
  exit 1
fi

cat >"${mapper_file}" <<'JSON'
{
  "name": "roles",
  "protocol": "openid-connect",
  "protocolMapper": "oidc-usermodel-client-role-mapper",
  "consentRequired": false,
  "config": {
    "usermodel.clientRoleMapping.clientId": "helios-api",
    "usermodel.clientRoleMapping.rolePrefix": "",
    "claim.name": "roles",
    "jsonType.label": "String",
    "multivalued": "true",
    "access.token.claim": "true",
    "id.token.claim": "true",
    "userinfo.token.claim": "true",
    "introspection.token.claim": "true"
  }
}
JSON

set_step "reconciling the roles protocol mapper"
mappers_document="$(
  "${KCADM}" get \
    "client-scopes/${roles_scope_id}/protocol-mappers/models" \
    --config "${config_file}" \
    -r "${REALM}" \
    --fields id,name \
    --format csv \
    --noquotes
)"
roles_mapper_id="$(
  optional_single_object_id "${ROLES_SCOPE} protocol mapper" \
    "${mappers_document}" "${ROLES_SCOPE}"
)"
if [ -z "${roles_mapper_id}" ]; then
  "${KCADM}" create \
    "client-scopes/${roles_scope_id}/protocol-mappers/models" \
    --config "${config_file}" \
    -r "${REALM}" \
    -f "${mapper_file}" >/dev/null
else
  require_uuid "${ROLES_SCOPE} protocol mapper" "${roles_mapper_id}"
  {
    printf '{\n  "id": "%s",\n' "${roles_mapper_id}"
    sed '1d' "${mapper_file}"
  } >"${mapper_update_file}"
  "${KCADM}" update \
    "client-scopes/${roles_scope_id}/protocol-mappers/models/${roles_mapper_id}" \
    --config "${config_file}" \
    -r "${REALM}" \
    -f "${mapper_update_file}" >/dev/null
fi

set_step "building the helios-api role scope mapping"
printf '[\n' >"${scope_roles_file}"
for index in "${!REQUIRED_ROLES[@]}"; do
  role="${REQUIRED_ROLES[${index}]}"
  role_document="$(
    "${KCADM}" get "clients/${api_client_id}/roles/${role}" \
      --config "${config_file}" \
      -r "${REALM}"
  )"
  if ! printf '%s\n' "${role_document}" | grep -Fq "\"name\" : \"${role}\""; then
    echo "Keycloak client ${API_CLIENT} is missing role ${role}." >&2
    exit 1
  fi
  if [ "${index}" -gt 0 ]; then
    printf ',\n' >>"${scope_roles_file}"
  fi
  printf '%s' "${role_document}" >>"${scope_roles_file}"
done
printf '\n]\n' >>"${scope_roles_file}"

# POST is set-like in Keycloak and therefore safe on every provisioning run.
set_step "assigning helios-api roles to the helios-bff scope"
"${KCADM}" create \
  "clients/${bff_client_id}/scope-mappings/clients/${api_client_id}" \
  --config "${config_file}" \
  -r "${REALM}" \
  -f "${scope_roles_file}" >/dev/null

set_step "reconciling the DR operator account"
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

set_step "setting the DR operator temporary password"
"${KCADM}" set-password \
  --config "${config_file}" \
  -r "${REALM}" \
  --userid "${user_id}" \
  --new-password "${HELIOS_DR_OPERATOR_PASSWORD}" \
  --temporary >/dev/null

set_step "assigning roles to the DR operator"
"${KCADM}" add-roles \
  --config "${config_file}" \
  -r "${REALM}" \
  --uid "${user_id}" \
  --cclientid "${API_CLIENT}" \
  --rolename tickets.read \
  --rolename tickets.write \
  --rolename automation.execute >/dev/null

set_step "verifying the effective helios-bff scope"
effective_scope_roles="$(
  "${KCADM}" get \
    "clients/${bff_client_id}/evaluate-scopes/scope-mappings/${api_client_id}/granted" \
    --config "${config_file}" \
    -r "${REALM}"
)"
require_roles_in_document "Effective ${BFF_CLIENT} role scope" "${effective_scope_roles}"

set_step "verifying the generated ID token"
id_token_example="$(
  "${KCADM}" get \
    "clients/${bff_client_id}/evaluate-scopes/generate-example-id-token" \
    --config "${config_file}" \
    -r "${REALM}" \
    -q "userId=${user_id}" \
    -q "scope=openid"
)"
id_token_roles="$(printf '%s\n' "${id_token_example}" | top_level_roles_claim)"
require_roles_in_document "Generated ID token roles claim" "${id_token_roles}"

set_step "verifying the generated access token"
access_token_example="$(
  "${KCADM}" get \
    "clients/${bff_client_id}/evaluate-scopes/generate-example-access-token" \
    --config "${config_file}" \
    -r "${REALM}" \
    -q "userId=${user_id}" \
    -q "scope=openid"
)"
access_token_roles="$(printf '%s\n' "${access_token_example}" | top_level_roles_claim)"
require_roles_in_document "Generated access token roles claim" "${access_token_roles}"

echo "DR operator and BFF token contract reconciled; password change is required at first login."
