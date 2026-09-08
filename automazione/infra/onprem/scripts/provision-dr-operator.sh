#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ONPREM_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
KUBECTL_BIN="${KUBECTL:-kubectl}"
NAMESPACE=helios-identity
JOB=helios-dr-operator-provisioner

"${KUBECTL_BIN}" -n "${NAMESPACE}" rollout status deployment/keycloak --timeout=300s
for secret in keycloak-bootstrap-admin helios-dr-operator; do
  "${KUBECTL_BIN}" -n "${NAMESPACE}" get "secret/${secret}" >/dev/null
done

# The realm import is create-only, while this script is also the supported
# repair path for an existing realm. Refresh the mounted provisioner before
# recreating the Job so a credentials reset cannot execute stale logic.
echo "Refreshing provisioner ConfigMap from ${ONPREM_DIR}/keycloak/provision/provision-dr-operator.sh" >&2
"${KUBECTL_BIN}" -n "${NAMESPACE}" create configmap helios-identity-provisioner \
  --from-file="provision-dr-operator.sh=${ONPREM_DIR}/keycloak/provision/provision-dr-operator.sh" \
  --dry-run=client \
  -o yaml | "${KUBECTL_BIN}" apply -f - >/dev/null

# A Job spec is immutable. Removing only this bounded, ephemeral Job makes
# interrupted and repeated provisioning converge on the same user and roles.
"${KUBECTL_BIN}" -n "${NAMESPACE}" delete "job/${JOB}" \
  --ignore-not-found \
  --wait=true >/dev/null
"${KUBECTL_BIN}" create -f "${ONPREM_DIR}/identity/operator-provision-job.yaml" >/dev/null

if ! "${KUBECTL_BIN}" -n "${NAMESPACE}" wait \
  --for=condition=complete \
  "job/${JOB}" \
  --timeout=180s; then
  pods="$(
    "${KUBECTL_BIN}" -n "${NAMESPACE}" get pods \
      -l "job-name=${JOB}" \
      -o name
  )"
  for pod in ${pods}; do
    echo "===== ${pod} =====" >&2
    "${KUBECTL_BIN}" -n "${NAMESPACE}" logs "${pod}" \
      --all-containers=true \
      --prefix=true >&2 || true
  done
  echo "===== job/${JOB} status =====" >&2
  "${KUBECTL_BIN}" -n "${NAMESPACE}" describe "job/${JOB}" >&2 || true
  echo "===== deployment/keycloak (last 10 minutes) =====" >&2
  "${KUBECTL_BIN}" -n "${NAMESPACE}" logs deployment/keycloak \
    --since=10m \
    --tail=200 >&2 || true
  exit 1
fi

"${KUBECTL_BIN}" -n "${NAMESPACE}" logs "job/${JOB}"
