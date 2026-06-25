FROM alpine:3.20
ARG TERRAFORM_VERSION=1.9.8
ARG TARGETARCH
RUN apk add --no-cache curl unzip aws-cli \
    && arch=${TARGETARCH:-amd64} \
    && curl -fsSLo /tmp/terraform.zip "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_${arch}.zip" \
    && unzip -q /tmp/terraform.zip -d /usr/local/bin \
    && rm /tmp/terraform.zip
WORKDIR /workspace
