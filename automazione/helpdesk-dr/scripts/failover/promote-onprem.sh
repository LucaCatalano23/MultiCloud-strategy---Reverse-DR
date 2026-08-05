#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/../common/lib.sh"

require_ansible_coordinator

wait_for_k3s "${ONPREM_K3S_NAME}" exec_onprem

HELIOS_DR_NAMESPACE="${HELIOS_DR_NAMESPACE:-helios-desk}"
HELIOS_IDENTITY_NAMESPACE="${HELIOS_IDENTITY_NAMESPACE:-helios-identity}"
HELIOS_DR_WORKLOADS="${HELIOS_DR_WORKLOADS:-helios-ticket-service helios-automation-service helios-bff helios-web}"
HELIOS_DR_ACTIVE_REPLICAS="${HELIOS_DR_ACTIVE_REPLICAS:-1}"
HELIOS_KEYCLOAK_ISSUER="${HELIOS_KEYCLOAK_ISSUER:-https://auth.azienda.lan/realms/helios-desk}"
HELIOS_KEYCLOAK_AUDIENCE="${HELIOS_KEYCLOAK_AUDIENCE:-api://reverse-dr-helpdesk}"
HELIOS_KEYCLOAK_JWKS_URL="${HELIOS_KEYCLOAK_JWKS_URL:-http://keycloak.helios-identity.svc.cluster.local:8080/realms/helios-desk/protocol/openid-connect/certs}"

if ! [[ "${HELIOS_DR_ACTIVE_REPLICAS}" =~ ^[1-9][0-9]*$ ]]; then
  echo "HELIOS_DR_ACTIVE_REPLICAS must be a positive integer." >&2
  exit 1
fi

# Helios e' l'unica applicazione della PoC: se il suo namespace non esiste, la
# promozione deve fallire subito. Prima esisteva un fallback sul monolite
# `helpdesk-api`, che oggi renderebbe la promozione "riuscita" senza che nulla
# serva traffico.
if ! exec_onprem kubectl get namespace "${HELIOS_DR_NAMESPACE}" >/dev/null 2>&1; then
  echo "Namespace ${HELIOS_DR_NAMESPACE} non trovato: applica prima l'overlay Helios (infra/onprem)." >&2
  exit 1
fi

read -r -a helios_workloads <<<"${HELIOS_DR_WORKLOADS}"
if [ "${#helios_workloads[@]}" -eq 0 ]; then
  echo "HELIOS_DR_WORKLOADS cannot be empty." >&2
  exit 1
fi

for workload in "${helios_workloads[@]}"; do
  if ! [[ "${workload}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
    echo "Invalid Kubernetes deployment name in HELIOS_DR_WORKLOADS." >&2
    exit 1
  fi
  exec_onprem kubectl -n "${HELIOS_DR_NAMESPACE}" get "deployment/${workload}" >/dev/null
done

# Keycloak e' warm e di norma gia' ready qui; il timeout ampio copre pero' un suo
# riavvio con primo build Quarkus lento (vedi progressDeadlineSeconds nel manifest),
# cosi' un Keycloak lento non fa fallire una promozione altrimenti valida.
exec_onprem kubectl -n "${HELIOS_IDENTITY_NAMESPACE}" rollout status statefulset/keycloak-postgres --timeout=600s
exec_onprem kubectl -n "${HELIOS_IDENTITY_NAMESPACE}" rollout status deployment/keycloak --timeout=600s

discovery_path="/api/v1/namespaces/${HELIOS_IDENTITY_NAMESPACE}/services/http:keycloak:http/proxy/realms/helios-desk/.well-known/openid-configuration"
discovery_document="$(exec_onprem kubectl get --raw "${discovery_path}")"
if ! grep -Fq "${HELIOS_KEYCLOAK_ISSUER}" <<<"${discovery_document}"; then
  echo "Keycloak discovery does not expose the expected DR issuer." >&2
  exit 1
fi

for workload in "${helios_workloads[@]}"; do
  exec_onprem kubectl -n "${HELIOS_DR_NAMESPACE}" set env \
    "deployment/${workload}" \
    DR_ACTIVE=true
done
exec_onprem kubectl -n "${HELIOS_DR_NAMESPACE}" set env \
  deployment/helios-bff \
  SITE_MODE=dr \
  IDENTITY_PROVIDER=keycloak \
  OIDC_ISSUER_URL="${HELIOS_KEYCLOAK_ISSUER}" \
  OIDC_AUDIENCE="${HELIOS_KEYCLOAK_AUDIENCE}" \
  OIDC_JWKS_URL="${HELIOS_KEYCLOAK_JWKS_URL}" \
  OIDC_ROLES_CLAIM=roles \
  OIDC_REQUIRED_ALGORITHMS=RS256

for workload in "${helios_workloads[@]}"; do
  exec_onprem kubectl -n "${HELIOS_DR_NAMESPACE}" scale \
    "deployment/${workload}" \
    --replicas="${HELIOS_DR_ACTIVE_REPLICAS}"
  exec_onprem kubectl -n "${HELIOS_DR_NAMESPACE}" rollout status \
    "deployment/${workload}" \
    --timeout=300s
done

onprem_ready
set_helpdesk_dns "${ONPREM_K3S_IP}"

echo "On-prem promoted. ${HELPDESK_FQDN} -> ${ONPREM_K3S_IP}"
