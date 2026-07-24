#!/usr/bin/env bash
# Abilita l'unseal automatico di OpenBao dopo un riavvio del nodo.
#
# ATTIVAZIONE ESPLICITA, MAI UN DEFAULT. `install-openbao.sh` non chiama questo
# script: abilitare l'auto-unseal e' una decisione di sicurezza che deve restare
# un'azione deliberata e tracciabile.
#
# Che cosa si guadagna: il sito DR resta operativo senza intervento umano anche
# dopo un riavvio di LXD/WSL, requisito operativo di questa PoC.
#
# Che cosa si perde, senza giri di parole: le chiavi Shamir finiscono sullo
# stesso filesystem che ospita lo storage cifrato di OpenBao. Chi ottiene il
# disco del nodo ottiene lucchetto e chiave insieme, quindi il sigillo smette di
# proteggere da un furto del volume e protegge solo da un accesso applicativo
# non privilegiato. Resta comunque preferibile a Secret Kubernetes in chiaro in
# etcd, perche' l'accesso ai segreti continua a passare da policy, autenticazione
# e audit log di OpenBao.
#
# Uso:
#   export OPENBAO_UNSEAL_KEYS="chiave1 chiave2 chiave3"
#   export OPENBAO_ACCEPT_AUTO_UNSEAL_RISK=yes
#   bash enable-auto-unseal.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
NODE="${OPENBAO_NODE:-vault-openbao}"

: "${OPENBAO_UNSEAL_KEYS:?OPENBAO_UNSEAL_KEYS must contain the Shamir key shares, space separated}"

# Conferma esplicita: senza, lo script non procede. Un'automazione che abbassa
# le garanzie di sicurezza non deve poter essere eseguita per inerzia.
if [ "${OPENBAO_ACCEPT_AUTO_UNSEAL_RISK:-}" != "yes" ]; then
  cat >&2 <<'EOF'
L'auto-unseal colloca le chiavi Shamir sullo stesso nodo dello storage cifrato.
Conferma di aver compreso il compromesso impostando:
  export OPENBAO_ACCEPT_AUTO_UNSEAL_RISK=yes
EOF
  exit 1
fi

read -r -a unseal_keys <<<"${OPENBAO_UNSEAL_KEYS}"
if [ "${#unseal_keys[@]}" -eq 0 ]; then
  echo "OPENBAO_UNSEAL_KEYS non contiene alcuna chiave." >&2
  exit 1
fi

umask 077
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/openbao-auto-unseal.XXXXXX")"
trap 'rm -rf "${work_dir}"' EXIT

# Una chiave per riga: il runner le legge in sequenza fino a raggiungere la
# soglia, senza sapere quante ne servano.
printf '%s\n' "${unseal_keys[@]}" >"${work_dir}/keys"

cat >"${work_dir}/openbao-auto-unseal" <<'RUNNER'
#!/bin/sh
# Runner dell'unseal automatico. Idempotente: se OpenBao e' gia' dissigillato
# non fa nulla, cosi' un riavvio del servizio non produce errori spuri.
set -eu

BAO_ADDR="https://127.0.0.1:8200"
BAO_CACERT="/etc/openbao/tls/tls.crt"
KEYS_FILE="/etc/openbao/unseal/keys"
export BAO_ADDR BAO_CACERT

health() {
  curl -sf --cacert "${BAO_CACERT}" --output /dev/null \
    --write-out '%{http_code}' "${BAO_ADDR}/v1/sys/health" 2>/dev/null || echo 000
}

status="$(health)"
if [ "${status}" = "200" ] || [ "${status}" = "429" ]; then
  echo "OpenBao gia' dissigillato."
  exit 0
fi

# Le chiavi passano da stdin e non da argv: la process list del nodo e'
# leggibile da qualunque utente locale.
while IFS= read -r share; do
  [ -n "${share}" ] || continue
  printf '%s' "${share}" | bao operator unseal - >/dev/null 2>&1 || true
  status="$(health)"
  if [ "${status}" = "200" ] || [ "${status}" = "429" ]; then
    echo "OpenBao dissigillato."
    exit 0
  fi
done <"${KEYS_FILE}"

echo "Soglia di unseal non raggiunta: OpenBao resta sigillato." >&2
exit 1
RUNNER

echo "Installazione runner e chiavi su ${NODE}..."
lxc exec "${NODE}" -- install -d -o root -g root -m 0700 /etc/openbao/unseal
lxc file push "${work_dir}/keys" "${NODE}/etc/openbao/unseal/keys" \
  --mode=0400 --uid=0 --gid=0
lxc file push "${work_dir}/openbao-auto-unseal" "${NODE}/usr/local/sbin/openbao-auto-unseal" \
  --mode=0700 --uid=0 --gid=0
lxc file push "${VAULT_DIR}/config/openbao-auto-unseal.service" \
  "${NODE}/etc/systemd/system/openbao-auto-unseal.service" --mode=0644 --uid=0 --gid=0

lxc exec "${NODE}" -- systemctl daemon-reload
lxc exec "${NODE}" -- systemctl enable --now openbao-auto-unseal.service

echo "Verifica dello stato effettivo del vault..."
bash "${SCRIPT_DIR}/verify-openbao.sh"

cat <<'EOF'

Auto-unseal attivo: OpenBao tornera' dissigillato da solo dopo un riavvio.
Le chiavi risiedono in /etc/openbao/unseal/keys (root, 0400) sul nodo.
Conserva comunque una copia delle chiavi FUORI dal laboratorio: se il nodo si
perde, senza di esse lo storage e' irrecuperabile.
EOF
