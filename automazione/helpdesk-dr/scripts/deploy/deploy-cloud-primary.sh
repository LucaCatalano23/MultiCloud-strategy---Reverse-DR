#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/../common/lib.sh"

wait_for_k3s "${CLOUD_K3S_NAME}" exec_cloud
copy_to_container "${CLOUD_K3S_NAME}" "${ROOT_DIR}" "/tmp/helpdesk-dr"
apply_helpdesk_runtime_secrets exec_cloud

exec_cloud sh -lc "kubectl kustomize --load-restrictor=LoadRestrictionsNone /tmp/helpdesk-dr/manifests/kubernetes/cloud | kubectl apply -f -"
localstack_url="$(discover_localstack_endpoint exec_cloud)"
localstack_ip="${localstack_url#http://}"
localstack_ip="${localstack_ip%%:*}"
exec_cloud sh -lc "cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: localstack
  namespace: ${APP_NAMESPACE}
spec:
  ports:
    - name: aws-edge
      port: 4566
      targetPort: 4566
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: localstack
  namespace: ${APP_NAMESPACE}
  labels:
    kubernetes.io/service-name: localstack
addressType: IPv4
ports:
  - name: aws-edge
    protocol: TCP
    port: 4566
endpoints:
  - addresses: [\"${localstack_ip}\"]
EOF"
exec_cloud kubectl -n "${APP_NAMESPACE}" rollout status deployment/postgres --timeout=180s
exec_cloud kubectl -n "${APP_NAMESPACE}" rollout status deployment/helpdesk-api --timeout=180s

set_helpdesk_dns "${CLOUD_K3S_IP}"
echo "Cloud primary deployed. ${HELPDESK_FQDN} -> ${CLOUD_K3S_IP}"
