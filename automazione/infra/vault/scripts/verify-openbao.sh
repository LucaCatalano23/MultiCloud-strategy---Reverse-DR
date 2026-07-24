#!/usr/bin/env bash
# Preflight OpenBao: raggiungibile E dissigillato.
#
# Perche' esiste: durante il failover i pod Helios non possono partire se
# External Secrets Operator non riesce a materializzare i loro Secret. Un
# OpenBao irraggiungibile o sigillato produrrebbe un sito DR promosso, con il
# DNS gia' spostato, e pod bloccati in CreateContainerConfigError. Questo
# controllo fa fallire il playbook PRIMA dello switch DNS.
set -euo pipefail

BAO_ADDR="${BAO_ADDR:-https://vault.azienda.lan:8200}"
BAO_CACERT="${BAO_CACERT:-}"
TIMEOUT_SECONDS="${OPENBAO_PREFLIGHT_TIMEOUT:-10}"

curl_args=(--fail --silent --show-error --max-time "${TIMEOUT_SECONDS}")
if [ -n "${BAO_CACERT}" ]; then
  curl_args+=(--cacert "${BAO_CACERT}")
fi

# /v1/sys/health e' l'unico endpoint interrogabile senza autenticazione, ed e'
# proprio cio' che serve: sapere se il vault e' utilizzabile, non leggerne il
# contenuto.
#
# Codici di stato: 200 inizializzato/dissigillato/attivo, 429 standby,
# 501 non inizializzato, 503 sigillato. `--fail` scarterebbe tutto tranne 200,
# quindi lo status va letto esplicitamente per poter distinguere le cause.
status="$(curl "${curl_args[@]/--fail/}" --output /dev/null --write-out '%{http_code}' \
  "${BAO_ADDR}/v1/sys/health" || true)"

case "${status}" in
  200)
    echo "OpenBao raggiungibile e dissigillato (${BAO_ADDR})."
    ;;
  429)
    echo "OpenBao in standby ma dissigillato (${BAO_ADDR})."
    ;;
  501)
    echo "OpenBao non inizializzato: esegui infra/vault/scripts/configure-openbao.sh." >&2
    exit 1
    ;;
  503)
    cat >&2 <<'EOF'
OpenBao e' SIGILLATO: i pod del sito DR non potrebbero leggere i propri segreti.
Dissigillalo sul nodo vault-openbao prima di promuovere:
  lxc exec vault-openbao -- bao operator unseal
EOF
    exit 1
    ;;
  000)
    echo "OpenBao irraggiungibile a ${BAO_ADDR} (timeout o TLS non valido)." >&2
    exit 1
    ;;
  *)
    echo "OpenBao ha risposto con uno stato inatteso: ${status}." >&2
    exit 1
    ;;
esac
