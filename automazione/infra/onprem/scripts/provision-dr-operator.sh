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
  "${KUBECTL_BIN}" -n "${NAMESPACE}" logs "job/${JOB}" >&2 || true
  exit 1
fi

"${KUBECTL_BIN}" -n "${NAMESPACE}" logs "job/${JOB}"
