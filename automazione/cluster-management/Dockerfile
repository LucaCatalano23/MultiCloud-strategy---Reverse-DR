FROM ubuntu:22.04

ARG DEBIAN_FRONTEND=noninteractive
ARG KUBECTL_VERSION=1.31.4
ARG KIND_VERSION=0.26.0
ARG HELM_VERSION=3.16.2
ARG ARGOCD_VERSION=2.13.0
ARG TARGETARCH

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates curl docker.io git gnupg lsb-release python3-pip software-properties-common \
    && add-apt-repository --yes --update ppa:ansible/ansible \
    && apt-get install -y --no-install-recommends ansible \
    && arch="${TARGETARCH:-amd64}" \
    && curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${arch}/kubectl" \
    && curl -fsSLo /usr/local/bin/kind "https://kind.sigs.k8s.io/dl/v${KIND_VERSION}/kind-linux-${arch}" \
    && curl -fsSLo /tmp/helm.tar.gz "https://get.helm.sh/helm-v${HELM_VERSION}-linux-${arch}.tar.gz" \
    && tar -xzf /tmp/helm.tar.gz -C /tmp \
    && mv /tmp/linux-${arch}/helm /usr/local/bin/helm \
    && curl -fsSLo /usr/local/bin/argocd "https://github.com/argoproj/argo-cd/releases/download/v${ARGOCD_VERSION}/argocd-linux-${arch}" \
    && chmod +x /usr/local/bin/kubectl /usr/local/bin/kind /usr/local/bin/helm /usr/local/bin/argocd \
    && pip3 install --no-cache-dir kubernetes==31.0.0 \
    && ansible-galaxy collection install kubernetes.core:5.0.0 \
    && rm -rf /var/lib/apt/lists/* /tmp/helm.tar.gz /tmp/linux-${arch}

WORKDIR /workspace
