#!/usr/bin/env bash
# Installa OpenBao sul nodo `vault-openbao` del laboratorio.
#
# Va eseguito dall'host WSL: usa `lxc exec`, non presuppone un kubeconfig e non
# tocca il cluster k3s. L'inizializzazione (init/unseal) resta un passo separato
# e manuale (`bao operator init`, poi configure-openbao.sh), perche' produce le
# chiavi Shamir e il root token: materiale che non deve transitare da uno script
# non presidiato.
#
# Installazione dal tarball ufficiale, non dal .deb: il tarball contiene solo il
# binario `bao`, cosi' la systemd unit e il layout di config restano interamente
# sotto il nostro controllo (openbao.hcl, /etc/openbao, utente di servizio),
# invece di dipendere dalle scelte opinate del pacchetto .deb.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

NODE="${OPENBAO_NODE:-vault-openbao}"
# Verificare la versione su https://github.com/openbao/openbao/releases prima di
# eseguire: qui non viene indovinata una release "ultima" a runtime, cosi'
# l'installazione resta riproducibile. La `v` iniziale e' tollerata.
OPENBAO_VERSION="${OPENBAO_VERSION:?OPENBAO_VERSION must be set, e.g. 2.6.1}"
VERSION="${OPENBAO_VERSION#v}"
ARCH="${OPENBAO_ARCH:-amd64}"
# Asset ufficiale (confermato in checksums.txt della release): prefisso
# `openbao_`, versione SENZA `v`. La variante `openbao-hsm_` serve solo con un HSM.
ARCHIVE="openbao_${VERSION}_linux_${ARCH}.tar.gz"
BASE_URL="https://github.com/openbao/openbao/releases/download/v${VERSION}"

: "${OPENBAO_TLS_CERT_FILE:?OPENBAO_TLS_CERT_FILE must point to the vault TLS certificate}"
: "${OPENBAO_TLS_KEY_FILE:?OPENBAO_TLS_KEY_FILE must point to the vault TLS private key}"

if [ ! -r "${OPENBAO_TLS_CERT_FILE}" ] || [ ! -r "${OPENBAO_TLS_KEY_FILE}" ]; then
  echo "I file TLS indicati non sono leggibili." >&2
  exit 1
fi

echo "Installazione OpenBao ${VERSION} su ${NODE}..."
lxc exec "${NODE}" -- apt-get update
lxc exec "${NODE}" -- env DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates

# Scarica archivio e checksums.txt della release. La verifica sha256 da
# checksums.txt intercetta un download corrotto o parziale; per l'autenticita'
# vera andrebbe verificata la firma GPG (checksums.txt.gpgsig), qui omessa per
# semplicita' di laboratorio. Un OPENBAO_SHA256 esplicito, se fornito, ha
# priorita' e permette il pinning.
lxc exec "${NODE}" -- curl -fsSL -o "/tmp/${ARCHIVE}" "${BASE_URL}/${ARCHIVE}"
lxc exec "${NODE}" -- curl -fsSL -o "/tmp/openbao-checksums.txt" "${BASE_URL}/checksums.txt"

if [ -n "${OPENBAO_SHA256:-}" ]; then
  lxc exec "${NODE}" -- sh -c "printf '%s  /tmp/%s\n' '${OPENBAO_SHA256}' '${ARCHIVE}' | sha256sum -c -"
else
  lxc exec "${NODE}" -- sh -c "cd /tmp && grep ' ${ARCHIVE}\$' openbao-checksums.txt | sha256sum -c -"
fi

# Estrazione del solo binario `bao` in /usr/local/bin.
lxc exec "${NODE}" -- tar -xzf "/tmp/${ARCHIVE}" -C /usr/local/bin bao
lxc exec "${NODE}" -- chmod 0755 /usr/local/bin/bao
lxc exec "${NODE}" -- rm -f "/tmp/${ARCHIVE}" /tmp/openbao-checksums.txt
lxc exec "${NODE}" -- /usr/local/bin/bao version

# Utente di servizio non privilegiato dedicato.
lxc exec "${NODE}" -- sh -c 'id openbao >/dev/null 2>&1 || useradd --system --home /var/lib/openbao --shell /usr/sbin/nologin openbao'
lxc exec "${NODE}" -- install -d -o openbao -g openbao -m 0700 /var/lib/openbao/data
lxc exec "${NODE}" -- install -d -o root -g openbao -m 0750 /etc/openbao /etc/openbao/tls

lxc file push "${VAULT_DIR}/config/openbao.hcl" "${NODE}/etc/openbao/openbao.hcl" \
  --mode=0640 --uid=0 --gid=0
lxc file push "${OPENBAO_TLS_CERT_FILE}" "${NODE}/etc/openbao/tls/tls.crt" --mode=0644 --uid=0 --gid=0
lxc file push "${OPENBAO_TLS_KEY_FILE}" "${NODE}/etc/openbao/tls/tls.key" --mode=0640 --uid=0 --gid=0
lxc exec "${NODE}" -- chgrp openbao /etc/openbao/openbao.hcl /etc/openbao/tls/tls.key

# Unit systemd sotto il nostro controllo: la stessa a cui si aggancia
# openbao-auto-unseal.service (opt-in).
lxc file push "${VAULT_DIR}/config/openbao.service" "${NODE}/etc/systemd/system/openbao.service" \
  --mode=0644 --uid=0 --gid=0

lxc exec "${NODE}" -- systemctl daemon-reload
lxc exec "${NODE}" -- systemctl enable --now openbao.service
lxc exec "${NODE}" -- systemctl is-active openbao.service

cat <<'EOF'

OpenBao e' installato e avviato, ma parte SIGILLATO e non inizializzato.
Inizializza una sola volta (conserva chiavi e root token fuori dal lab):
  lxc exec vault-openbao -- env BAO_ADDR=https://127.0.0.1:8200 \
    BAO_CACERT=/etc/openbao/tls/tls.crt bao operator init
Dissigilla (3 volte) e prosegui con:
  bash infra/vault/scripts/configure-openbao.sh
EOF
