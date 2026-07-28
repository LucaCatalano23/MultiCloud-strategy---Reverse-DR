#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/../common/lib.sh"

check() {
  local description="$1"
  shift
  printf '%-44s' "${description}"
  if "$@" >/tmp/helpdesk-dr-check.log 2>&1; then
    echo "OK"
  else
    echo "FAIL"
    cat /tmp/helpdesk-dr-check.log
    exit 1
  fi
}

check "on-prem k3s nodes" exec_onprem kubectl get nodes
# OpenBao e Keycloak devono essere sempre operativi: senza vault dissigillato i
# pod non possono materializzare i propri Secret, e il failover promuoverebbe un
# sito incapace di servire traffico. Il check gira SUL nodo vault via 127.0.0.1
# (cert locale), quindi non dipende da DNS del cluster ne' dal CA fuori dal nodo.
# `bao status` esce 0 se dissigillato, 2 se sigillato, 1 se irraggiungibile.
check "openbao unsealed" exec_vault env \
  BAO_ADDR=https://127.0.0.1:8200 \
  BAO_CACERT=/etc/openbao/tls/tls.crt \
  /usr/local/bin/bao status
check "on-prem Lambda DR adapter" exec_onprem kubectl -n lambda-dr rollout status deployment/event-adapter --timeout=30s
check "on-prem ticket Lambda runtime" exec_onprem kubectl -n lambda-dr rollout status deployment/lambda-helpdesk-ticket-processor --timeout=30s
mode="$(read_dr_state)"
if [ "${mode}" = "dr" ]; then
  check "on-prem helios ready" onprem_ready
else
  # Sul sito cloud simulato non gira piu' un'applicazione da interrogare: dopo la
  # rimozione del monolite resta il data plane Kubernetes come failure domain.
  check "cloud k3s nodes" probe_cloud kubectl get nodes
  check "cloud data plane ready" cloud_ready
fi
check "dns resolves helpdesk" exec_dns dig +short "${HELPDESK_FQDN}"
check "ansible sees helpdesk dns" exec_ansible dig +short "@${DNS_SERVER_IP}" "${HELPDESK_FQDN}"

echo "Helpdesk DR checks passed."
