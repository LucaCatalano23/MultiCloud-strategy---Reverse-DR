#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/../common/lib.sh"

failover_lock="$(runtime_dir)/failover.lock"
exec 8>"${failover_lock}"
if ! flock -n 8; then
  echo "A failover operation is already in progress." >&2
  exit 1
fi

wait_for_k3s "${ONPREM_K3S_NAME}" exec_onprem
copy_to_container "${ONPREM_K3S_NAME}" "${ROOT_DIR}" "/tmp/helpdesk-dr"

if [ -d "${ROOT_DIR}/infra/onprem" ]; then
  onprem_infra_dir="${ROOT_DIR}/infra/onprem"
elif [ -d "${ROOT_DIR}/../infra/onprem" ]; then
  onprem_infra_dir="${ROOT_DIR}/../infra/onprem"
else
  echo "The Helios on-prem infrastructure directory is missing." >&2
  exit 1
fi

# The monorepo keeps infra next to helpdesk-dr, while the Git source of truth
# publishes it below /opt/helpdesk-dr/infra.
if [ "${onprem_infra_dir}" != "${ROOT_DIR}/infra/onprem" ]; then
  copy_to_container \
    "${ONPREM_K3S_NAME}" \
    "${onprem_infra_dir}" \
    "/tmp/helpdesk-dr/infra/onprem"
fi

exec_onprem kubectl apply -f /tmp/helpdesk-dr/infra/onprem/namespaces.yaml

# I Secret non sono piu' un prerequisito: li materializza External Secrets
# Operator dopo che l'overlay e' stato applicato, leggendoli da OpenBao.
# Verificare la loro presenza *prima* del deploy fallirebbe sempre. Cio' che
# deve esistere prima e' l'infrastruttura che li produce: il vault raggiungibile
# e dissigillato, e le CRD dell'operatore installate nel cluster.
# Preflight sul nodo vault via 127.0.0.1 (cert locale), non via rete: non dipende
# da /etc/hosts/CA sull'host. `bao status` esce 0 se dissigillato.
if ! exec_vault env BAO_ADDR=https://127.0.0.1:8200 \
    BAO_CACERT=/etc/openbao/tls/tls.crt /usr/local/bin/bao status >/dev/null 2>&1; then
  cat >&2 <<'EOF'
OpenBao non e' utilizzabile (irraggiungibile o sigillato): i workload Helios non
potrebbero ottenere le proprie credenziali. Vedi automazione/infra/vault/README.md.
EOF
  exit 1
fi

if ! exec_onprem kubectl get crd externalsecrets.external-secrets.io >/dev/null 2>&1; then
  cat >&2 <<'EOF'
External Secrets Operator non e' installato nel cluster on-prem.
Installalo prima del deploy: vedi automazione/infra/onprem/README.md.
EOF
  exit 1
fi

migrate_legacy_literal_environment() {
  # Le prime versioni del DR scrivevano queste variabili come `value:`. La
  # versione corrente usa ConfigMap refs; il strategic-merge di Kubernetes non
  # puo' passare direttamente da value a valueFrom, perche' nel patch
  # intermedio entrambi risultano presenti. Rimuoviamo solo le chiavi migrate
  # e solo a workload spenti; l'apply successivo le reinserisce atomiche.
  local deployment
  local variables
  local replicas
  local variable
  local -a removals

  while IFS='|' read -r deployment variables; do
    [ -n "${deployment}" ] || continue
    if ! exec_onprem kubectl -n helios-desk get "deployment/${deployment}" >/dev/null 2>&1; then
      continue
    fi
    replicas="$(exec_onprem kubectl -n helios-desk get "deployment/${deployment}" -o jsonpath='{.spec.replicas}')"
    if [ "${replicas:-0}" != "0" ]; then
      echo "Refusing legacy environment migration for active deployment/${deployment}. Demote DR before deploying standby." >&2
      return 1
    fi
    removals=()
    for variable in ${variables}; do
      removals+=("${variable}-")
    done
    exec_onprem kubectl -n helios-desk set env "deployment/${deployment}" "${removals[@]}"
  done <<'EOF'
helios-ticket-service|DR_ACTIVE OIDC_ISSUER_URL OIDC_AUDIENCE OIDC_JWKS_URL OIDC_ROLES_CLAIM OIDC_REQUIRED_ALGORITHMS
helios-automation-service|DR_ACTIVE OIDC_ISSUER_URL OIDC_AUDIENCE OIDC_JWKS_URL OIDC_ROLES_CLAIM OIDC_REQUIRED_ALGORITHMS
helios-bff|DR_ACTIVE SITE_MODE SITE_NAME IDENTITY_PROVIDER APPLICATION_PUBLIC_ORIGIN OIDC_ISSUER_URL OIDC_AUDIENCE OIDC_JWKS_URL OIDC_ROLES_CLAIM OIDC_REQUIRED_ALGORITHMS OIDC_SCOPES OIDC_CLIENT_ID OIDC_CLIENT_AUTH_METHOD OIDC_REDIRECT_URI OIDC_POST_LOGOUT_REDIRECT_URI OIDC_AUTHORIZATION_ENDPOINT OIDC_TOKEN_ENDPOINT OIDC_END_SESSION_ENDPOINT TICKET_SERVICE_URL AUTOMATION_SERVICE_URL
EOF
}

apply_postgres_runtime_secret exec_onprem
exec_onprem sh -lc "kubectl kustomize --load-restrictor=LoadRestrictionsNone /tmp/helpdesk-dr/manifests/kubernetes/onprem | kubectl apply -f -"
migrate_legacy_literal_environment
exec_onprem sh -lc "kubectl kustomize --load-restrictor=LoadRestrictionsNone /tmp/helpdesk-dr/infra/onprem | kubectl apply -f -"

exec_onprem kubectl -n "${APP_NAMESPACE}" rollout status deployment/postgres --timeout=180s
exec_onprem kubectl -n helios-identity rollout status statefulset/keycloak-postgres --timeout=300s
exec_onprem kubectl -n helios-identity rollout status deployment/keycloak --timeout=300s

HELIOS_DR_NAMESPACE="${HELIOS_DR_NAMESPACE:-helios-desk}"
HELIOS_DR_WORKLOADS="${HELIOS_DR_WORKLOADS:-helios-ticket-service helios-automation-service helios-bff helios-web}"
read -r -a helios_workloads <<<"${HELIOS_DR_WORKLOADS}"
for workload in "${helios_workloads[@]}"; do
  exec_onprem kubectl -n "${HELIOS_DR_NAMESPACE}" scale "deployment/${workload}" --replicas=0
done

# Inizializza anche il routing normale: senza questo passaggio una zona DNS
# lasciata da una precedente demo puo' continuare a puntare cloud-k3s invece
# del CNAME ALB configurato. Fallire qui e' sicuro: il controller non viene
# armato finche' il primary non e' effettivamente pubblicato dal DNS del lab.
set_primary_helpdesk_dns
write_dr_state "primary"
echo "On-prem standby deployed. Keycloak is warm; Helios application workloads remain at zero until promotion."
