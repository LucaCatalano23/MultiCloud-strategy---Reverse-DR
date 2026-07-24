#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/../common/lib.sh"

command -v docker >/dev/null 2>&1 || {
  echo "Docker is required to build the on-prem Lambda artifacts." >&2
  exit 1
}

lambda_root="${ROOT_DIR}/../lambda-dr"
image_archive="${ROOT_DIR}/.state/lambda-dr-images.tar"
mkdir -p "$(dirname "${image_archive}")"

docker compose -f "${lambda_root}/docker-compose.yml" build lambda-runtime event-adapter
docker save \
  reverse-dr/lambda-runtime:python3.11 \
  reverse-dr/event-adapter:latest \
  -o "${image_archive}"

# L'ordine qui e' significativo. `lxc file push` non avvia il container: se il
# push avviene a container spento, l'archivio finisce in un /tmp che il boot
# successivo ripulisce, e l'import fallisce con "no such file" a ogni retry.
# Inoltre `k3s ctr` ha bisogno del socket containerd, che esiste solo dopo che
# k3s e' partito. Avviare e attendere prima del push risolve entrambi i casi.
wait_for_k3s "${ONPREM_K3S_NAME}" exec_onprem

# /var/tmp invece di /tmp perche' non e' soggetto a pulizia automatica ne' a
# essere montato come tmpfs: l'archivio deve sopravvivere fino all'import.
lxc_retry file push "${image_archive}" "${ONPREM_K3S_NAME}/var/tmp/lambda-dr-images.tar"
exec_onprem k3s ctr images import /var/tmp/lambda-dr-images.tar
exec_onprem rm -f /var/tmp/lambda-dr-images.tar
rm -f "${image_archive}"

copy_to_container "${ONPREM_K3S_NAME}" "${lambda_root}/kubernetes" "/tmp/lambda-dr-kubernetes"
exec_onprem kubectl apply -k /tmp/lambda-dr-kubernetes
exec_onprem kubectl -n lambda-dr rollout status deployment/event-adapter --timeout=180s
exec_onprem kubectl -n lambda-dr rollout status deployment/lambda-helpdesk-ticket-processor --timeout=180s

echo "On-prem Lambda DR data plane is ready."

