#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${ROOT_DIR}/docker-compose.yml"
KUBECONFIG_FILE="${ROOT_DIR}/.state/cloud-kubeconfig"

command -v docker >/dev/null 2>&1 || {
  cat >&2 <<'EOF'
Docker CLI is not available in this WSL distribution.
This lab requires Docker Engine to run natively in the same Ubuntu WSL
distribution as LXD. Follow step 0 in automazione/RUNBOOK_SCENARIO_REALE.md.
EOF
  exit 1
}

# Keep the lab independent from a Docker Desktop credential helper left in
# ~/.docker/config.json. Set DOCKER_CONFIG explicitly to use another store.
if [ -z "${DOCKER_CONFIG:-}" ]; then
  export DOCKER_CONFIG="${ROOT_DIR}/.state/docker-config"
  install -d -m 0700 "${DOCKER_CONFIG}"
  if [ ! -f "${DOCKER_CONFIG}/config.json" ]; then
    (umask 077 && printf '{}\n' >"${DOCKER_CONFIG}/config.json")
  fi
fi

if ! docker info >/dev/null; then
  cat >&2 <<'EOF'
Docker CLI exists, but it cannot reach a Docker Engine.
Start the native service with:
  sudo systemctl enable --now docker

Do not mix Docker Desktop WSL integration with the native Engine required by
this lab. See step 0 in automazione/RUNBOOK_SCENARIO_REALE.md.
EOF
  exit 1
fi

docker_operating_system="$(docker info --format '{{.OperatingSystem}}')"
case "${docker_operating_system}" in
  *Docker\ Desktop*)
    cat >&2 <<EOF
Unsupported Docker daemon detected: ${docker_operating_system}

LocalStack and LXD must share the same Ubuntu WSL network namespace so the EKS
control plane can reach cloud-k3s. Disable Docker Desktop integration for this
distro and install Docker Engine natively as described in step 0 of
automazione/RUNBOOK_SCENARIO_REALE.md.
EOF
    exit 1
    ;;
esac

if ! docker compose version >/dev/null 2>&1; then
  cat >&2 <<'EOF'
Docker Compose v2 is missing. Install the docker-compose-plugin package from
Docker's official Ubuntu repository; see step 0 in the runbook.
EOF
  exit 1
fi

if [ -z "${LOCALSTACK_AUTH_TOKEN:-}" ]; then
  echo "LOCALSTACK_AUTH_TOKEN is required to activate LocalStack for AWS." >&2
  exit 1
fi

if [[ "${LOCALSTACK_AUTH_TOKEN}" != ls-* ]] ||
  [[ "${LOCALSTACK_AUTH_TOKEN}" =~ [[:space:]] ]] ||
  [[ "${LOCALSTACK_AUTH_TOKEN}" == *"'"* ]] ||
  [[ "${LOCALSTACK_AUTH_TOKEN}" == *'"'* ]]; then
  cat >&2 <<'EOF'
LOCALSTACK_AUTH_TOKEN is malformed.
It must be the real LocalStack Auth Token, start with "ls-", and contain no
whitespace or quote characters. Do not use the <token> placeholder.
Retrieve or rotate it at https://app.localstack.cloud/workspace/auth-tokens.
EOF
  exit 1
fi

export LOCALSTACK_EKS_API_ENABLED="${LOCALSTACK_EKS_API_ENABLED:-false}"
export LOCALSTACK_SERVICES="${LOCALSTACK_SERVICES:-ec2,iam,lambda,s3,sts}"
case "${LOCALSTACK_EKS_API_ENABLED}" in
  true)
    case ",${LOCALSTACK_SERVICES}," in
      *,eks,*) ;;
      *) export LOCALSTACK_SERVICES="${LOCALSTACK_SERVICES},eks" ;;
    esac
    ;;
  false) ;;
  *)
    echo "LOCALSTACK_EKS_API_ENABLED must be true or false." >&2
    exit 1
    ;;
esac

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

  container_status="$(docker inspect --format '{{.State.Status}}' reverse-dr-localstack 2>/dev/null || true)"
  case "${container_status}" in
    dead|exited|restarting)
      exit_code="$(docker inspect --format '{{.State.ExitCode}}' reverse-dr-localstack 2>/dev/null || true)"
      docker compose -f "${COMPOSE_FILE}" logs --tail=100 localstack >&2
      docker compose -f "${COMPOSE_FILE}" stop localstack >/dev/null 2>&1 || true
      if [ "${exit_code}" = "55" ]; then
        cat >&2 <<'EOF'
LocalStack stopped with exit code 55: license activation failed.
Verify that the Auth Token is current and assigned to an active LocalStack
license, then export it again and rerun.
EOF
      else
        echo "LocalStack stopped before becoming healthy (status=${container_status}, exit=${exit_code:-unknown})." >&2
      fi
      exit 1
      ;;
  esac

  if [ "${attempt}" -eq 120 ]; then
    docker compose -f "${COMPOSE_FILE}" logs --tail=200 localstack >&2
    echo "LocalStack did not become healthy." >&2
    exit 1
  fi
  sleep 2
done

localstack_resources_ready() {
  if [ "${LOCALSTACK_EKS_API_ENABLED}" = "true" ] &&
    ! docker compose -f "${COMPOSE_FILE}" exec -T localstack \
      awslocal eks describe-cluster --name helpdesk-cloud >/dev/null 2>&1; then
    return 1
  fi

  docker compose -f "${COMPOSE_FILE}" exec -T localstack \
    awslocal s3api head-bucket --bucket reverse-dr-helpdesk-backups >/dev/null 2>&1 &&
    docker compose -f "${COMPOSE_FILE}" exec -T localstack \
      awslocal lambda get-function --function-name helpdesk-ticket-processor >/dev/null 2>&1
}

for attempt in $(seq 1 120); do
  if localstack_resources_ready; then
    echo "LocalStack cloud simulation is ready on port 4566 (EKS API enabled: ${LOCALSTACK_EKS_API_ENABLED})."
    exit 0
  fi
  if [ "${attempt}" -eq 120 ]; then
    docker compose -f "${COMPOSE_FILE}" logs --tail=200 localstack >&2
    echo "LocalStack initialization hooks did not provision all AWS resources." >&2
    exit 1
  fi
  sleep 2
done
