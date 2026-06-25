#!/usr/bin/env bash
set -Eeuo pipefail

echo ">>> Bootstrap Cluster Primario (Datacenter) <<<"
KIND_CLUSTER_NAME=reverse-dr ./scripts/00_bootstrap_cluster.sh

echo ">>> Bootstrap Cluster Secondario (DR) <<<"
KIND_CLUSTER_NAME=reverse-dr-dr ./scripts/00_bootstrap_cluster.sh

echo ">>> Installazione K8GB sul Primario <<<"
./scripts/01_install_k8gb.sh reverse-dr

echo ">>> Installazione K8GB sul Secondario <<<"
./scripts/01_install_k8gb.sh reverse-dr-dr

echo ">>> Multi-Cluster K8GB Deployato con Successo! <<<"
