#!/usr/bin/env bash
set -Eeuo pipefail

CLUSTER_NAME="${1:-reverse-dr}"
echo "Installazione K8GB sul cluster ${CLUSTER_NAME}..."

# Helm repo per K8GB
helm repo add k8gb https://www.k8gb.io
helm repo update

# Determina il GeoTag in base al nome del cluster
if [[ "${CLUSTER_NAME}" == "reverse-dr" ]]; then
  GEOTAG="eu-prod"
else
  GEOTAG="eu-dr"
fi

helm upgrade --install k8gb k8gb/k8gb \
  --namespace k8gb --create-namespace \
  --set k8gb.edgeDNSZone=reverse-dr.local \
  --set k8gb.clusterGeoTag=${GEOTAG} \
  --set k8gb.extdns.extraArgs="--txt-owner-id=${CLUSTER_NAME}" \
  --set k8gb.extdns.provider=coredns \
  --wait

echo "K8GB installato su ${CLUSTER_NAME} con GeoTag ${GEOTAG}!"
