#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${ROOT_DIR}/docker-compose.yml"
KUBECONFIG_FILE="${ROOT_DIR}/.state/cloud-kubeconfig"

command -v docker >/dev/null 2>&1 || {
  echo "Docker is required to start LocalStack." >&2
  exit 1
}

if [ -z "${LOCALSTACK_AUTH_TOKEN:-}" ]; then
  echo "LOCALSTACK_AUTH_TOKEN is required because EKS needs LocalStack Ultimate, Enterprise, or Student." >&2
  exit 1
fi

if [ ! -s "${KUBECONFIG_FILE}" ]; then
  echo "Missing ${KUBECONFIG_FILE}. Run helpdesk-dr/scripts/poc/setup-cloud-sim.sh first." >&2
  exit 1
fi

docker compose -f "${COMPOSE_FILE}" up --build -d

for attempt in $(seq 1 120); do
  status="$(docker inspect --format '{{.State.Health.Status}}' reverse-dr-localstack 2>/dev/null || true)"
  if [ "${status}" = "healthy" ]; then
    break
  fi
  if [ "${attempt}" -eq 120 ]; then
    docker compose -f "${COMPOSE_FILE}" logs --tail=200 localstack >&2
    echo "LocalStack did not become healthy." >&2
    exit 1
  fi
  sleep 2
done

for attempt in $(seq 1 120); do
  if docker compose -f "${COMPOSE_FILE}" exec -T localstack \
      awslocal eks describe-cluster --name helpdesk-cloud >/dev/null 2>&1 && \
    docker compose -f "${COMPOSE_FILE}" exec -T localstack \
      awslocal s3api head-bucket --bucket reverse-dr-helpdesk-backups >/dev/null 2>&1 && \
    docker compose -f "${COMPOSE_FILE}" exec -T localstack \
      awslocal lambda get-function --function-name helpdesk-ticket-processor >/dev/null 2>&1; then
    echo "LocalStack cloud simulation is ready on port 4566."
    exit 0
  fi
  if [ "${attempt}" -eq 120 ]; then
    docker compose -f "${COMPOSE_FILE}" logs --tail=200 localstack >&2
    echo "LocalStack initialization hooks did not provision all AWS resources." >&2
    exit 1
  fi
  sleep 2
done
