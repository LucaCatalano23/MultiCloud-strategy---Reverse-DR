#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/../common/lib.sh"

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

required_secrets=(
  "helios-identity/keycloak-postgres"
  "helios-identity/keycloak-bootstrap-admin"
  "helios-identity/helios-bff-oidc"
  "helios-identity/helios-dr-operator"
  "helios-identity/helios-identity-tls"
  "helios-desk/helios-bff-runtime"
  "helios-desk/helios-app-database"
  "helios-desk/helios-app-tls"
)
for secret_ref in "${required_secrets[@]}"; do
  namespace="${secret_ref%%/*}"
  secret_name="${secret_ref##*/}"
  if ! exec_onprem kubectl -n "${namespace}" get secret "${secret_name}" >/dev/null 2>&1; then
    cat >&2 <<EOF
Missing Secret/${secret_name} in namespace ${namespace}.
Provision secrets out-of-band with infra/onprem/scripts/create-secrets.sh before deploying standby.
EOF
    exit 1
  fi
done

apply_helpdesk_runtime_secrets exec_onprem
exec_onprem sh -lc "kubectl kustomize --load-restrictor=LoadRestrictionsNone /tmp/helpdesk-dr/manifests/kubernetes/onprem | kubectl apply -f -"
exec_onprem sh -lc "kubectl kustomize --load-restrictor=LoadRestrictionsNone /tmp/helpdesk-dr/infra/onprem | kubectl apply -f -"

exec_onprem kubectl -n "${APP_NAMESPACE}" rollout status deployment/postgres --timeout=180s
exec_onprem kubectl -n helios-identity rollout status statefulset/keycloak-postgres --timeout=300s
exec_onprem kubectl -n helios-identity rollout status deployment/keycloak --timeout=300s

exec_onprem kubectl -n "${APP_NAMESPACE}" scale deployment/helpdesk-api --replicas="${ONPREM_STANDBY_REPLICAS:-1}"
if [ "${ONPREM_STANDBY_REPLICAS:-1}" -gt 0 ]; then
  pod="$(wait_for_deployment_pod exec_onprem app=helpdesk-api)"
  wait_for_pod_running exec_onprem "${pod}"
fi

HELIOS_DR_NAMESPACE="${HELIOS_DR_NAMESPACE:-helios-desk}"
HELIOS_DR_WORKLOADS="${HELIOS_DR_WORKLOADS:-helios-ticket-service helios-automation-service helios-bff helios-web}"
read -r -a helios_workloads <<<"${HELIOS_DR_WORKLOADS}"
for workload in "${helios_workloads[@]}"; do
  exec_onprem kubectl -n "${HELIOS_DR_NAMESPACE}" scale "deployment/${workload}" --replicas=0
done

write_dr_state "primary"
echo "On-prem standby deployed. Keycloak is warm; Helios application workloads remain at zero until promotion."
