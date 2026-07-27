#!/usr/bin/env bash
# Configura OpenBao come vault manager del sito DR:
# mount KV v2, policy per namespace, autenticazione Kubernetes per k3s.
#
# NON inizializza e NON dissigilla: `bao operator init` produce chiavi Shamir e
# token di root, materiale che deve passare per le mani di un operatore e non
# finire nell'output di uno script. Lo script pretende un OpenBao gia'
# inizializzato e dissigillato, e un BAO_TOKEN amministrativo nell'ambiente.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

NODE="${OPENBAO_NODE:-vault-openbao}"
KV_MOUNT="${OPENBAO_KV_MOUNT:-helios}"
K3S_NODE="${ONPREM_K3S_NAME:-k3s-datacenter}"
K3S_API="${ONPREM_K3S_API:-https://10.10.3.10:6443}"

: "${BAO_TOKEN:?BAO_TOKEN (token amministrativo OpenBao) must be set}"

bao_exec() {
  lxc exec "${NODE}" -- env \
    BAO_ADDR="${BAO_ADDR:-https://127.0.0.1:8200}" \
    BAO_TOKEN="${BAO_TOKEN}" \
    BAO_CACERT=/etc/openbao/tls/tls.crt \
    bao "$@"
}

# Preflight sul nodo, via lxc exec (127.0.0.1), non dall'host: questo script
# gira sull'host, dove `vault.azienda.lan` non risolve ancora. Coerente con il
# resto di configure-openbao, che parla a OpenBao solo attraverso bao_exec.
echo "Verifica che OpenBao sia raggiungibile e dissigillato sul nodo..."
if ! bao_exec status >/dev/null 2>&1; then
  cat >&2 <<'EOF'
OpenBao non risulta raggiungibile o e' ancora sigillato sul nodo vault-openbao.
Esegui prima, una sola volta:
  lxc exec vault-openbao -- env BAO_ADDR=https://127.0.0.1:8200 \
    BAO_CACERT=/etc/openbao/tls/tls.crt bao operator init
poi dissigilla 3 volte:
  lxc exec vault-openbao -- env BAO_ADDR=https://127.0.0.1:8200 \
    BAO_CACERT=/etc/openbao/tls/tls.crt bao operator unseal
EOF
  exit 1
fi

echo "Mount KV v2 '${KV_MOUNT}'..."
if ! bao_exec secrets list -format=json | grep -q "\"${KV_MOUNT}/\""; then
  bao_exec secrets enable -path="${KV_MOUNT}" -version=2 kv
else
  echo "Mount ${KV_MOUNT}/ gia' presente."
fi

echo "Applicazione policy..."
for policy in helios-desk-read helios-identity-read; do
  lxc file push "${VAULT_DIR}/policies/${policy}.hcl" \
    "${NODE}/tmp/${policy}.hcl" --mode=0600 --uid=0 --gid=0
  bao_exec policy write "${policy}" "/tmp/${policy}.hcl"
  lxc exec "${NODE}" -- rm -f "/tmp/${policy}.hcl"
done

echo "Abilitazione autenticazione Kubernetes..."
if ! bao_exec auth list -format=json | grep -q '"kubernetes/"'; then
  bao_exec auth enable kubernetes
fi

# OpenBao deve poter validare i token dei ServiceAccount presentati dai pod.
# Serve il CA del cluster e un token di un ServiceAccount abilitato alla
# TokenReview: e' il reviewer creato da infra/onprem/secrets/external-secrets.yaml.
k3s_ca="$(lxc exec "${K3S_NODE}" -- cat /var/lib/rancher/k3s/server/tls/server-ca.crt)"
reviewer_jwt="$(lxc exec "${K3S_NODE}" -- kubectl -n helios-desk create token openbao-token-reviewer --duration=8760h)"

umask 077
tmp_ca="$(mktemp)"
trap 'rm -f "${tmp_ca}"' EXIT
printf '%s\n' "${k3s_ca}" >"${tmp_ca}"
lxc file push "${tmp_ca}" "${NODE}/tmp/k3s-ca.crt" --mode=0600 --uid=0 --gid=0

bao_exec write auth/kubernetes/config \
  kubernetes_host="${K3S_API}" \
  kubernetes_ca_cert=@/tmp/k3s-ca.crt \
  token_reviewer_jwt="${reviewer_jwt}" \
  disable_local_ca_jwt=true
lxc exec "${NODE}" -- rm -f /tmp/k3s-ca.crt

echo "Creazione ruoli legati ai ServiceAccount di External Secrets..."
bao_exec write auth/kubernetes/role/helios-desk \
  bound_service_account_names=helios-secrets-sync \
  bound_service_account_namespaces=helios-desk \
  policies=helios-desk-read \
  ttl=1h

bao_exec write auth/kubernetes/role/helios-identity \
  bound_service_account_names=helios-secrets-sync \
  bound_service_account_namespaces=helios-identity \
  policies=helios-identity-read \
  ttl=1h

# External Secrets Operator deve fidarsi del certificato di OpenBao. La CA e'
# materiale pubblico, quindi vive in una ConfigMap e non in un Secret; e' pero'
# specifica dell'ambiente, per questo non e' versionata nel repository.
echo "Pubblicazione della CA di OpenBao nei namespace Helios..."
for namespace in helios-desk helios-identity; do
  lxc exec "${K3S_NODE}" -- sh -c \
    "kubectl -n ${namespace} create configmap openbao-ca \
      --from-literal=ca.crt=\"\$(cat /dev/stdin)\" \
      --dry-run=client -o yaml | kubectl apply -f -" \
    <"${OPENBAO_CA_FILE:?OPENBAO_CA_FILE must point to the OpenBao CA certificate}"
done

echo "OpenBao configurato. Popola i segreti con: bash ${SCRIPT_DIR}/seed-secrets.sh"
