#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/../common/lib.sh"

check() {
  local description="$1"
  shift
  printf '%-44s' "${description}"
  if "$@" >/tmp/helpdesk-dr-check.log 2>&1; then
    echo "OK"
  else
    echo "FAIL"
    cat /tmp/helpdesk-dr-check.log
    exit 1
  fi
}

check "on-prem k3s nodes" exec_onprem kubectl get nodes
check "on-prem Lambda DR adapter" exec_onprem kubectl -n lambda-dr rollout status deployment/event-adapter --timeout=30s
check "on-prem ticket Lambda runtime" exec_onprem kubectl -n lambda-dr rollout status deployment/lambda-helpdesk-ticket-processor --timeout=30s
mode="$(read_dr_state)"
if [ "${mode}" = "dr" ]; then
  check "on-prem helpdesk ready" onprem_ready
else
  check "cloud k3s nodes" probe_cloud kubectl get nodes
  check "LocalStack gateway" curl -fsS "$(localstack_endpoint)/_localstack/health"
  check "LocalStack EKS control plane" aws_local eks describe-cluster --name "${EKS_CLUSTER_NAME}"
  check "LocalStack S3 backup bucket" aws_local s3api head-bucket --bucket "${BACKUP_S3_BUCKET}"
  check "cloud AWS Lambda" aws_local lambda get-function --function-name "${HELPDESK_LAMBDA_FUNCTION_NAME}"
  check "cloud helpdesk live" probe_cloud curl -fsS -H "Host: ${HELPDESK_FQDN}" "http://127.0.0.1/health/live"
  check "cloud helpdesk ready" cloud_ready
fi
check "dns resolves helpdesk" exec_dns dig +short "${HELPDESK_FQDN}"
check "ansible sees helpdesk dns" exec_ansible dig +short "@${DNS_SERVER_IP}" "${HELPDESK_FQDN}"

echo "Helpdesk DR checks passed."
