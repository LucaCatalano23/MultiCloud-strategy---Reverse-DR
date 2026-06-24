#!/usr/bin/env bash
set -Eeuo pipefail

CLUSTER_NAME="${KIND_CLUSTER_NAME:-reverse-dr}"
NETWORK_NAME="${DATACENTER_NETWORK:-rete-datacenter}"
APP_IMAGE="${APP_IMAGE:-reverse-dr-app:local}"
CALICO_VERSION="${CALICO_VERSION:-v3.29.1}"
CLUSTER_CREATED=false

if ! kind get clusters | grep -Fxq "${CLUSTER_NAME}"; then
  kind create cluster \
    --name "${CLUSTER_NAME}" \
    --config kubernetes/kind-config.yml
  CLUSTER_CREATED=true
fi

CONTROL_PLANE="${CLUSTER_NAME}-control-plane"
if ! docker inspect "${CONTROL_PLANE}" --format '{{json .NetworkSettings.Networks}}' | grep -q "${NETWORK_NAME}"; then
  docker network connect "${NETWORK_NAME}" "${CONTROL_PLANE}"
fi
for management_container in cluster-management identity-failover-controller; do
  if docker inspect "${management_container}" >/dev/null 2>&1 \
    && ! docker inspect "${management_container}" --format '{{json .NetworkSettings.Networks}}' | grep -q '"kind"'; then
    docker network connect kind "${management_container}"
  fi
done

# Il DR Landing Site è una capacità interna alla rete datacenter. L'accesso utente
# rimane mediato dal boundary router e dal load balancer datacenter.
# Il kubeconfig di Kind usa il loopback dell'host Docker, non quello del bastion.
# Il DNS del control-plane è incluso nei certificati generati da Kind.
kubectl config set-cluster "kind-${CLUSTER_NAME}" \
  --server="https://${CONTROL_PLANE}:6443"

kubectl label node "${CONTROL_PLANE}" ingress-ready=true --overwrite

if [[ "${CLUSTER_CREATED}" == "true" ]]; then
  kubectl apply --filename \
    "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"
  kubectl wait --namespace kube-system \
    --for=condition=Ready pod --selector=k8s-app=calico-node --timeout=180s
fi

docker build --tag "${APP_IMAGE}" --file app/Dockerfile .
kind load docker-image "${APP_IMAGE}" --name "${CLUSTER_NAME}"

echo "Verifica Nginx Ingress Controller..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=300s

if [[ "${CLUSTER_CREATED}" == "true" ]]; then
  echo "Installazione ArgoCD..."
  kubectl create namespace argocd || true
  kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
  # Aspettiamo che l'API server accetti i webhook
  sleep 10
  kubectl wait --namespace argocd \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/name=argocd-server \
    --timeout=300s

  echo "Installazione Kube Prometheus Stack..."
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
  helm repo update
  helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
    --namespace monitoring --create-namespace \
    --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
    --wait

  echo "Installazione OPA Gatekeeper..."
  helm repo add gatekeeper https://open-policy-agent.github.io/gatekeeper/charts
  helm repo update
  helm upgrade --install gatekeeper gatekeeper/gatekeeper \
    --namespace gatekeeper-system --create-namespace \
    --wait
  echo "Cluster ${CLUSTER_NAME} creato con Nginx Ingress, ArgoCD, Prometheus e OPA."
else
  echo "Cluster ${CLUSTER_NAME} esistente: rete datacenter e Nginx Ingress verificati."
fi
