FROM python:3.12-alpine
ARG KUBECTL_VERSION=1.31.4
ARG TARGETARCH
RUN apk add --no-cache curl \
    && arch=${TARGETARCH:-amd64} \
    && curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${arch}/kubectl" \
    && chmod +x /usr/local/bin/kubectl \
    && apk del curl
WORKDIR /workspace
