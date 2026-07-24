#!/usr/bin/env bash
# Installa OpenBao sul nodo `vault-openbao` del laboratorio.
#
# Va eseguito dall'host WSL: usa `lxc exec`, non presuppone un kubeconfig e non
# tocca il cluster k3s. L'inizializzazione (init/unseal) resta un passo separato
# e manuale in `configure-openbao.sh`, perche' produce le chiavi Shamir e il
# token di root: materiale che non deve transitare da uno script non presidiato.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

NODE="${OPENBAO_NODE:-vault-openbao}"
# Verificare la versione disponibile su https://github.com/openbao/openbao/releases
# prima di eseguire: qui non viene indovinata una release "ultima" a runtime,
# cosi' l'installazione resta riproducibile e revisionabile.
OPENBAO_VERSION="${OPENBAO_VERSION:?OPENBAO_VERSION must be set, e.g. 2.4.1}"
OPENBAO_SHA256="${OPENBAO_SHA256:-}"
ARCH="${OPENBAO_ARCH:-amd64}"
PACKAGE="bao_${OPENBAO_VERSION}_linux_${ARCH}.deb"
BASE_URL="https://github.com/openbao/openbao/releases/download/v${OPENBAO_VERSION}"

: "${OPENBAO_TLS_CERT_FILE:?OPENBAO_TLS_CERT_FILE must point to the vault TLS certificate}"
: "${OPENBAO_TLS_KEY_FILE:?OPENBAO_TLS_KEY_FILE must point to the vault TLS private key}"

if [ ! -r "${OPENBAO_TLS_CERT_FILE}" ] || [ ! -r "${OPENBAO_TLS_KEY_FILE}" ]; then
  echo "I file TLS indicati non sono leggibili." >&2
  exit 1
fi

echo "Installazione OpenBao ${OPENBAO_VERSION} su ${NODE}..."
lxc exec "${NODE}" -- apt-get update
lxc exec "${NODE}" -- env DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates

lxc exec "${NODE}" -- curl -fsSL -o "/tmp/${PACKAGE}" "${BASE_URL}/${PACKAGE}"

# Il checksum e' opzionale solo per non bloccare un lab offline, ma va fornito:
# senza, si sta installando un binario privilegiato senza verificarne l'origine.
if [ -n "${OPENBAO_SHA256}" ]; then
  lxc exec "${NODE}" -- sh -c "printf '%s  /tmp/%s\n' '${OPENBAO_SHA256}' '${PACKAGE}' | sha256sum -c -"
else
  echo "ATTENZIONE: OPENBAO_SHA256 non impostato, il pacchetto non viene verificato." >&2
fi

lxc exec "${NODE}" -- apt-get install -y "/tmp/${PACKAGE}"
lxc exec "${NODE}" -- rm -f "/tmp/${PACKAGE}"

lxc exec "${NODE}" -- install -d -o openbao -g openbao -m 0700 /var/lib/openbao/data
lxc exec "${NODE}" -- install -d -o root -g openbao -m 0750 /etc/openbao /etc/openbao/tls

lxc file push "${VAULT_DIR}/config/openbao.hcl" "${NODE}/etc/openbao/openbao.hcl" \
  --mode=0640 --uid=0 --gid=0
lxc file push "${OPENBAO_TLS_CERT_FILE}" "${NODE}/etc/openbao/tls/tls.crt" --mode=0644 --uid=0 --gid=0
lxc file push "${OPENBAO_TLS_KEY_FILE}" "${NODE}/etc/openbao/tls/tls.key" --mode=0640 --uid=0 --gid=0
lxc exec "${NODE}" -- chgrp openbao /etc/openbao/openbao.hcl /etc/openbao/tls/tls.key

lxc exec "${NODE}" -- systemctl enable --now openbao
lxc exec "${NODE}" -- systemctl is-active openbao

cat <<'EOF'

OpenBao e' installato e avviato, ma parte SIGILLATO e non inizializzato.
Prosegui con:
  bash infra/vault/scripts/configure-openbao.sh
EOF
