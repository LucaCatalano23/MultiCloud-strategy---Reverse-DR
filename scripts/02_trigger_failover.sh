#!/usr/bin/env bash
set -Eeuo pipefail

CLUSTER_NAME="${KIND_CLUSTER_NAME:-reverse-dr}"
export APP_IMAGE="${APP_IMAGE:-reverse-dr-app:local}"

kind get clusters | grep -Fxq "${CLUSTER_NAME}" || {
  echo "Cluster Kind ${CLUSTER_NAME} assente. Eseguire scripts/00_bootstrap_cluster.sh." >&2
  exit 1
}

echo "Attivazione Island Mode: il traffico egress dell'app sarà limitato ai servizi sovrani."
ansible-playbook \
  --inventory codice_iac/ansible/inventory.ini \
  codice_iac/ansible/playbook_reverse_dr.yml

kubectl --namespace reverse-dr rollout status deployment/reverse-dr-app --timeout=180s
kubectl --namespace reverse-dr get pods,services,networkpolicy

echo "Il sito DR è pronto. Il controller GSLB commuterà il DNS dopo gli health check configurati."
echo "Stato corrente:"
cat /var/lib/gslb-control/status.json 2>/dev/null || echo "Controller GSLB non ancora disponibile."
