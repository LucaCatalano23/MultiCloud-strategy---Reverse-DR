#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/../common/lib.sh"

wait_for_k3s "${CLOUD_K3S_NAME}" exec_cloud
copy_to_container "${CLOUD_K3S_NAME}" "${ROOT_DIR}" "/tmp/helpdesk-dr"
apply_helpdesk_runtime_secrets exec_cloud

exec_cloud sh -lc "kubectl kustomize --load-restrictor=LoadRestrictionsNone /tmp/helpdesk-dr/manifests/kubernetes/cloud | kubectl apply -f -"
exec_cloud kubectl -n "${APP_NAMESPACE}" rollout status deployment/postgres --timeout=180s
exec_cloud kubectl -n "${APP_NAMESPACE}" rollout status deployment/helpdesk-api --timeout=180s

set_helpdesk_dns "${CLOUD_K3S_IP}"
echo "Cloud primary deployed. ${HELPDESK_FQDN} -> ${CLOUD_K3S_IP}"
