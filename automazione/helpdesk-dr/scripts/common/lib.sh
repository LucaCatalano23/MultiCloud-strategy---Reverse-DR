#!/usr/bin/env bash
set -euo pipefail

HELPDESK_DR_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${HELPDESK_DR_LIB_DIR}/../.." && pwd)"
# shellcheck source=../../config.defaults
source "${ROOT_DIR}/config.defaults"

HELPDESK_DR_CONFIG_PATH="${HELPDESK_DR_CONFIG_FILE:-${ROOT_DIR}/config.env}"
if [ ! -f "${HELPDESK_DR_CONFIG_PATH}" ] && [ -f /etc/helpdesk-dr/config.env ]; then
  HELPDESK_DR_CONFIG_PATH="/etc/helpdesk-dr/config.env"
fi
if [ ! -f "${HELPDESK_DR_CONFIG_PATH}" ]; then
  echo "Missing DR secrets file: ${HELPDESK_DR_CONFIG_PATH}" >&2
  echo "Copy config.env.example to config.env and provide local-only secrets." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "${HELPDESK_DR_CONFIG_PATH}"

: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD must be supplied by the DR secrets file}"

# Credenziali del solo PostgreSQL condiviso. Il Secret `helpdesk-aws`, che
# serviva al monolite rimosso per invocare AWS Lambda, non viene piu' creato:
# le credenziali AWS della generazione corrente arrivano da IRSA sul sito
# primario, non da un Secret statico nel cluster di laboratorio.
apply_postgres_runtime_secret() {
  local executor="$1"

  "${executor}" kubectl get namespace "${APP_NAMESPACE}" >/dev/null 2>&1 || \
    "${executor}" kubectl create namespace "${APP_NAMESPACE}"
  "${executor}" sh -c '
    set -eu
    kubectl -n "$1" create secret generic helpdesk-postgres \
      --from-literal=POSTGRES_DB="$2" \
      --from-literal=POSTGRES_USER="$3" \
      --from-literal=POSTGRES_PASSWORD="$4" \
      --dry-run=client -o yaml | kubectl apply -f -
  ' sh "${APP_NAMESPACE}" "${POSTGRES_DB}" "${POSTGRES_USER}" "${POSTGRES_PASSWORD}"
}

lxc_retry() {
  local attempt
  local max_attempts=6
  local delay=3

  for attempt in $(seq 1 "${max_attempts}"); do
    if lxc "$@"; then
      return 0
    fi
    if [ "${attempt}" -eq "${max_attempts}" ]; then
      echo "lxc $* failed after ${max_attempts} attempts" >&2
      return 1
    fi
    echo "lxc $* failed, retrying in ${delay}s (${attempt}/${max_attempts})..." >&2
    sleep "${delay}"
    delay=$((delay * 2))
  done
}

container_running() {
  [ "$(lxc_retry list "$1" -c s --format csv 2>/dev/null | tr '[:lower:]' '[:upper:]')" = "RUNNING" ]
}

container_exists() {
  lxc list "$1" -c n --format csv 2>/dev/null | grep -qx "$1"
}

ensure_container_started() {
  local container="$1"

  if container_running "${container}"; then
    return 0
  fi

  echo "Starting container ${container}..."
  lxc_retry start "${container}" || true
  for _ in $(seq 1 60); do
    if container_running "${container}"; then
      echo "Container ${container} is running."
      return 0
    fi
    sleep 1
  done

  echo "Container ${container} did not reach RUNNING state" >&2
  return 1
}

ensure_onprem_network_started() {
  ensure_container_started router-edge
  ensure_container_started router-dmz
  ensure_container_started router-datacenter
}

exec_cloud() {
  ensure_container_started "${CLOUD_K3S_NAME}"
  lxc_retry exec "${CLOUD_K3S_NAME}" -- "$@"
}

probe_cloud() {
  if ! container_running "${CLOUD_K3S_NAME}"; then
    return 1
  fi
  lxc_retry exec "${CLOUD_K3S_NAME}" -- "$@"
}

exec_onprem() {
  ensure_onprem_network_started
  ensure_container_started "${ONPREM_K3S_NAME}"
  lxc_retry exec "${ONPREM_K3S_NAME}" -- "$@"
}

# Comandi sul nodo OpenBao. Il preflight del vault gira qui via 127.0.0.1 con il
# certificato locale, non da ansible-node/host via rete: cosi' non dipende dalla
# risoluzione DNS del cluster ne' dalla distribuzione del CA fuori dal nodo.
exec_vault() {
  ensure_container_started "${VAULT_NODE_NAME:-vault-openbao}"
  lxc_retry exec "${VAULT_NODE_NAME:-vault-openbao}" -- "$@"
}

exec_dns() {
  ensure_container_started "${DNS_SERVER_NAME}"
  lxc_retry exec "${DNS_SERVER_NAME}" -- "$@"
}

exec_git() {
  ensure_container_started "${GIT_SERVER_NAME}"
  lxc_retry exec "${GIT_SERVER_NAME}" -- "$@"
}

exec_ansible() {
  ensure_onprem_network_started
  ensure_container_started "${ANSIBLE_NODE_NAME}"
  lxc_retry exec "${ANSIBLE_NODE_NAME}" -- "$@"
}

exec_ansible_once() {
  ensure_onprem_network_started
  ensure_container_started "${ANSIBLE_NODE_NAME}"
  lxc exec "${ANSIBLE_NODE_NAME}" -- "$@"
}

lxd_host_gateway() {
  local cidr
  cidr="$(lxc_retry network get lxdbr0 ipv4.address)"
  if [ -z "${cidr}" ] || [ "${cidr}" = "none" ]; then
    echo "lxdbr0 does not expose an IPv4 gateway" >&2
    return 1
  fi
  printf '%s\n' "${cidr%%/*}"
}

require_ansible_coordinator() {
  if [ "${DR_REQUIRE_ANSIBLE_NODE:-true}" != "true" ]; then
    return 0
  fi
  if [ "$(hostname -s)" != "${ANSIBLE_NODE_NAME}" ]; then
    cat >&2 <<EOF
DR orchestration is restricted to ${ANSIBLE_NODE_NAME}.
Run it through:
  bash scripts/poc/ansible-run.sh failover/run-ansible-failover
EOF
    return 1
  fi
}

state_dir() {
  local dir="${DR_STATE_DIR:-${ROOT_DIR}/.state}"
  mkdir -p "${dir}"
  printf '%s\n' "${dir}"
}

runtime_dir() {
  local dir="${DR_RUNTIME_DIR:-/run/helpdesk-dr}"
  mkdir -p "${dir}"
  printf '%s\n' "${dir}"
}

write_dr_state() {
  local state="$1"
  local dir
  local mode_tmp
  local updated_tmp
  dir="$(state_dir)"
  case "${state}" in
    primary | promoting | dr | reconcile) ;;
    *)
      echo "Invalid DR state: ${state}" >&2
      return 1
      ;;
  esac
  mode_tmp="${dir}/.mode.$$"
  updated_tmp="${dir}/.updated_at.$$"
  printf '%s\n' "${state}" >"${mode_tmp}"
  date -u +"%Y-%m-%dT%H:%M:%SZ" >"${updated_tmp}"
  chmod 0600 "${mode_tmp}" "${updated_tmp}"
  mv -f "${mode_tmp}" "${dir}/mode"
  mv -f "${updated_tmp}" "${dir}/updated_at"
}

read_dr_state() {
  local dir
  dir="$(state_dir)"
  if [ -f "${dir}/mode" ]; then
    cat "${dir}/mode"
  else
    printf 'unknown\n'
  fi
}

wait_for_deployment_stopped() {
  local exec_fn="$1"
  local namespace="$2"
  local deployment="$3"
  local state=''
  local spec_replicas
  local replicas
  local ready_replicas
  local available_replicas

  for _ in $(seq 1 120); do
    state="$("${exec_fn}" kubectl -n "${namespace}" get \
      "deployment/${deployment}" \
      -o jsonpath='{.spec.replicas},{.status.replicas},{.status.readyReplicas},{.status.availableReplicas}')"
    IFS=',' read -r spec_replicas replicas ready_replicas available_replicas <<<"${state}"
    if [ "${spec_replicas:-0}" = "0" ] && [ "${replicas:-0}" = "0" ] &&
      [ "${ready_replicas:-0}" = "0" ] && [ "${available_replicas:-0}" = "0" ]; then
      return 0
    fi
    sleep 1
  done

  echo "Deployment ${namespace}/${deployment} did not fully stop; replicas=${state}." >&2
  return 1
}

wait_for_k3s() {
  local target="$1"
  local exec_fn="$2"
  local attempt

  echo "Waiting for k3s on ${target}..."
  for attempt in $(seq 1 120); do
    if "${exec_fn}" kubectl get nodes >/dev/null 2>&1; then
      echo "k3s is ready on ${target}."
      return 0
    fi
    if [ $((attempt % 10)) -eq 0 ]; then
      echo "Still waiting for k3s on ${target} (${attempt}/120)..."
      lxc list "${target}" --format compact || true
      lxc exec "${target}" -- systemctl is-active k3s 2>/dev/null || true
    fi
    sleep 2
  done
  echo "k3s did not become ready on ${target}" >&2
  lxc list "${target}" --format compact >&2 || true
  lxc exec "${target}" -- systemctl status k3s --no-pager -l >&2 || true
  lxc exec "${target}" -- journalctl -u k3s -n 80 --no-pager >&2 || true
  return 1
}

install_k3s_if_missing() {
  local container="$1"
  local exec_fn="$2"

  if lxc exec "${container}" -- test -x /usr/local/bin/k3s >/dev/null 2>&1; then
    return 0
  fi

  "${exec_fn}" sh -lc "curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC='--disable traefik=false --write-kubeconfig-mode 644' sh -"
}

prepare_lxc_for_k3s() {
  local exec_fn="$1"

  "${exec_fn}" sh -lc "ln -sf /dev/console /dev/kmsg"
  "${exec_fn}" sh -lc "cat >/etc/tmpfiles.d/k3s-lxc.conf <<'EOF'
L /dev/kmsg - - - - /dev/console
EOF"
}

configure_lxc_k3s_container() {
  local container="$1"

  lxc_retry config set "${container}" security.nesting true
  lxc_retry config set "${container}" security.privileged true
  if [ "${ALLOW_LXC_WRITABLE_PROC_SYS:-false}" = "true" ]; then
    lxc_retry config set "${container}" raw.lxc "lxc.mount.auto = proc:rw sys:rw"
  fi
}

copy_to_container() {
  local container="$1"
  local src="$2"
  local dst="$3"
  lxc_retry exec "${container}" -- rm -rf "${dst}"
  lxc_retry exec "${container}" -- mkdir -p "${dst}"
  tar -C "${src}" -cf - . | lxc exec "${container}" -- tar -C "${dst}" -xf -
}

render_lab_dns_zone() {
  local serial
  serial="$(date +%s)"
  cat <<EOF
\$TTL 30
@ IN SOA server-dns.${LAB_DOMAIN}. admin.${LAB_DOMAIN}. (
  ${serial} 30 15 604800 30
)
@ IN NS server-dns.${LAB_DOMAIN}.
server-dns IN A ${DNS_SERVER_IP}
auth IN A ${ONPREM_K3S_IP}
git-server IN A ${GIT_SERVER_IP}
cloud-helpdesk IN A ${CLOUD_K3S_IP}
onprem-helpdesk IN A ${ONPREM_K3S_IP}
EOF
}

is_valid_ipv4_address() {
  local address="$1"
  local -a octets
  local octet

  [[ "${address}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  IFS='.' read -r -a octets <<<"${address}"
  for octet in "${octets[@]}"; do
    [ "${octet}" -le 255 ] || return 1
  done
}

normalize_dns_hostname() {
  local hostname="$1"
  local normalized

  normalized="${hostname%.}"
  if ! [[ "${normalized}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]; then
    echo 'DNS target must be a valid fully-qualified hostname.' >&2
    return 1
  fi
  printf '%s.\n' "${normalized}"
}

render_helpdesk_dns_zone() {
  local target="$1"
  local normalized_target
  local record_name="${HELPDESK_DNS_RECORD_NAME:-${HELPDESK_FQDN}}"
  local serial

  if ! [[ "${record_name}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]; then
    echo 'Helpdesk DNS record name must be a valid fully-qualified hostname.' >&2
    return 1
  fi
  normalized_target="$(normalize_dns_hostname "${target}")" || return 1
  target="${normalized_target}"
  serial="$(date +%s)"
  cat <<EOF
\$TTL 30
@ IN SOA server-dns.${LAB_DOMAIN}. admin.${LAB_DOMAIN}. (
  ${serial} 30 15 604800 30
)
@ IN NS server-dns.${LAB_DOMAIN}.
${record_name} IN CNAME ${target}
EOF
}

# Il target cloud reale e' il DNS name dell'ALB, non uno dei suoi IP: un ALB
# ruota gli IP senza preavviso. Il fallback CNAME conserva cloud-k3s simulato.
render_primary_helpdesk_dns_zone() {
  render_helpdesk_dns_zone "${CLOUD_DNS_TARGET:-${CLOUD_FALLBACK_DNS_TARGET}}"
}

render_onprem_helpdesk_dns_zone() {
  render_helpdesk_dns_zone "${ONPREM_DNS_TARGET}"
}

set_helpdesk_dns() {
  local zone_renderer="$1"
  local dr_runtime_dir
  local lab_zone_file
  local app_zone_file
  dr_runtime_dir="$(runtime_dir)"
  lab_zone_file="${dr_runtime_dir}/lab.zone.$$"
  app_zone_file="${dr_runtime_dir}/helpdesk.zone.$$"
  render_lab_dns_zone >"${lab_zone_file}"
  "${zone_renderer}" >"${app_zone_file}"
  exec_dns bash -lc "grep -q 'zone \"${LAB_DOMAIN}\"' /etc/bind/named.conf.local || cat >>/etc/bind/named.conf.local <<'EOF'
zone \"${LAB_DOMAIN}\" {
  type master;
  file \"/etc/bind/db.${LAB_DOMAIN}\";
};
EOF"
  # Le vecchie zone autorevoli (host-specific e terna.it) intercettavano anche
  # sts.terna.it. RPZ e' un override preciso della sola risposta Helios.
  exec_dns bash -lc "sed -i '/^zone \"${HELPDESK_FQDN}\" {/,/^};$/d; /^zone \"terna.it\" {/,/^};$/d' /etc/bind/named.conf.local; rm -f /etc/bind/db.${HELPDESK_FQDN} /etc/bind/db.terna.it; (grep -q 'zone \"${HELPDESK_DNS_ZONE}\"' /etc/bind/named.conf.local || grep -q 'zone \"${HELPDESK_DNS_ZONE}\"' /etc/bind/named.conf.d/lxc-lab.conf 2>/dev/null) || cat >>/etc/bind/named.conf.local <<'EOF'
zone \"${HELPDESK_DNS_ZONE}\" {
  type master;
  file \"/etc/bind/db.${HELPDESK_DNS_ZONE}\";
};
EOF"
  exec_dns bash -lc "install -d -m 0755 /etc/bind/named.conf.d; cat >/etc/bind/named.conf.d/helios-rpz-options.conf <<'EOF'
response-policy { zone \"${HELPDESK_DNS_ZONE}\"; };
EOF
grep -Fqx '  include \"/etc/bind/named.conf.d/helios-rpz-options.conf\";' /etc/bind/named.conf.options || sed -i '/^};$/i\\  include \"/etc/bind/named.conf.d/helios-rpz-options.conf\";' /etc/bind/named.conf.options"
  lxc_retry file push "${lab_zone_file}" "${DNS_SERVER_NAME}/etc/bind/db.${LAB_DOMAIN}"
  lxc_retry file push "${app_zone_file}" "${DNS_SERVER_NAME}/etc/bind/db.${HELPDESK_DNS_ZONE}"
  exec_dns named-checkconf
  exec_dns named-checkzone "${LAB_DOMAIN}" "/etc/bind/db.${LAB_DOMAIN}"
  exec_dns named-checkzone "${HELPDESK_DNS_ZONE}" "/etc/bind/db.${HELPDESK_DNS_ZONE}"
  exec_dns systemctl restart named
  rm -f "${lab_zone_file}" "${app_zone_file}"
}

set_primary_helpdesk_dns() {
  set_helpdesk_dns render_primary_helpdesk_dns_zone
}

set_onprem_helpdesk_dns() {
  set_helpdesk_dns render_onprem_helpdesk_dns_zone
}

cloud_ready_lxc() {
  probe_cloud kubectl get --raw /readyz >/dev/null
}

validate_cloud_probe_config() {
  local mode="${CLOUD_PROBE_MODE:-lxc-k3s}"
  local safe_path_pattern='^/[A-Za-z0-9._~/%?=&-]*$'
  local connect_timeout="${CLOUD_CONNECT_TIMEOUT_SECONDS:-5}"
  local healthcheck_timeout="${CLOUD_HEALTHCHECK_TIMEOUT_SECONDS:-10}"

  if ! [[ "${connect_timeout}" =~ ^[1-9][0-9]*$ ]]; then
    echo "CLOUD_CONNECT_TIMEOUT_SECONDS must be a positive integer." >&2
    return 1
  fi
  if ! [[ "${healthcheck_timeout}" =~ ^[1-9][0-9]*$ ]]; then
    echo "CLOUD_HEALTHCHECK_TIMEOUT_SECONDS must be a positive integer." >&2
    return 1
  fi
  if [ "${connect_timeout}" -gt "${healthcheck_timeout}" ]; then
    echo "CLOUD_CONNECT_TIMEOUT_SECONDS must not exceed CLOUD_HEALTHCHECK_TIMEOUT_SECONDS." >&2
    return 1
  fi

  case "${mode}" in
    lxc-k3s)
      return 0
      ;;
    https | http)
      # `http` esiste per gli ALB senza ACM: stesso probe, ma in chiaro e con
      # porta di default 80 invece di 443. CLOUD_TARGET_HOST accetta un IP oltre
      # all'hostname perche' senza DNS l'unico riferimento e' l'IP dell'ALB.
      local target_default_port=443
      if [ "${mode}" = "http" ]; then
        target_default_port=80
      fi
      if ! [[ "${CLOUD_TARGET_HOST:-}" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
        echo "CLOUD_TARGET_HOST must be an IP address or DNS hostname when CLOUD_PROBE_MODE=${mode}." >&2
        return 1
      fi
      if ! [[ "${CLOUD_TARGET_PORT:-${target_default_port}}" =~ ^[0-9]+$ ]] ||
        [ "${CLOUD_TARGET_PORT:-${target_default_port}}" -lt 1 ] ||
        [ "${CLOUD_TARGET_PORT:-${target_default_port}}" -gt 65535 ]; then
        echo "CLOUD_TARGET_PORT must be between 1 and 65535." >&2
        return 1
      fi
      if ! [[ "${CLOUD_HEALTHCHECK_PATH:-/health/ready}" =~ ${safe_path_pattern} ]]; then
        echo "CLOUD_HEALTHCHECK_PATH must be a safe absolute HTTP path." >&2
        return 1
      fi
      # I knob TLS valgono solo in https: un cert non attendibile (self-signed
      # importato in ACM) si gestisce fissando la CA (CLOUD_TARGET_CA_FILE) o,
      # in alternativa esclusiva, saltando la verifica (CLOUD_TARGET_INSECURE).
      if [ "${mode}" = "https" ]; then
        case "${CLOUD_TARGET_INSECURE:-false}" in
          true | false) ;;
          *)
            echo "CLOUD_TARGET_INSECURE must be true or false." >&2
            return 1
            ;;
        esac
        if [ -n "${CLOUD_TARGET_CA_FILE:-}" ] && [ "${CLOUD_TARGET_INSECURE:-false}" = "true" ]; then
          echo "CLOUD_TARGET_CA_FILE and CLOUD_TARGET_INSECURE are mutually exclusive." >&2
          return 1
        fi
        if [ -n "${CLOUD_TARGET_CA_FILE:-}" ] && [ ! -r "${CLOUD_TARGET_CA_FILE}" ]; then
          echo "CLOUD_TARGET_CA_FILE must point to a readable CA certificate." >&2
          return 1
        fi
      fi
      ;;
    *)
      echo "CLOUD_PROBE_MODE must be lxc-k3s, https or http." >&2
      return 1
      ;;
  esac
}

# Connette direttamente all'IP o al DNS name dell'ALB, ma mantiene
# heliospoc.terna.it come URL, Host e TLS SNI. In questo modo il probe continua a
# osservare il primary anche dopo che il DNS applicativo e' passato al DR. Con un
# cert non attendibile (es. self-signed importato in ACM) la verifica si rilassa
# via CLOUD_TARGET_CA_FILE (CA pinnata) o CLOUD_TARGET_INSECURE=true.
cloud_ready_https() {
  local response_file
  local status
  local tls_args=()
  validate_cloud_probe_config
  if [ -n "${CLOUD_TARGET_CA_FILE:-}" ]; then
    tls_args+=(--cacert "${CLOUD_TARGET_CA_FILE}")
  elif [ "${CLOUD_TARGET_INSECURE:-false}" = "true" ]; then
    tls_args+=(--insecure)
  fi
  response_file="$(mktemp "$(runtime_dir)/cloud-ready.XXXXXX")"
  if ! status="$(curl --fail --silent --show-error \
    "${tls_args[@]}" \
    --connect-timeout "${CLOUD_CONNECT_TIMEOUT_SECONDS:-5}" \
    --max-time "${CLOUD_HEALTHCHECK_TIMEOUT_SECONDS:-10}" \
    --connect-to \
    "${HELPDESK_FQDN}:443:${CLOUD_TARGET_HOST}:${CLOUD_TARGET_PORT:-443}" \
    --output "${response_file}" \
    --write-out '%{http_code}' \
    "https://${HELPDESK_FQDN}${CLOUD_HEALTHCHECK_PATH:-/health/ready}")"; then
    rm -f "${response_file}"
    return 1
  fi
  if [ "${status}" != "200" ] ||
    ! grep -Eq '"status"[[:space:]]*:[[:space:]]*"ready"' "${response_file}" ||
    ! grep -Eq '"service"[[:space:]]*:[[:space:]]*"helios-bff"' "${response_file}"; then
    rm -f "${response_file}"
    return 1
  fi
  rm -f "${response_file}"
}

# Variante senza TLS per ALB privi di ACM. Connette direttamente all'IP (o
# hostname) dell'ALB via HTTP in chiaro, ma tiene heliospoc.terna.it come Host per
# far combaciare la regola host-based dell'Ingress e osservare sempre il primary
# anche quando il DNS applicativo e' gia' passato al DR. Limiti (nessuna verifica
# TLS; l'IP dell'ALB e' dinamico e va aggiornato a mano; l'ALB deve servire HTTP
# senza ssl-redirect, altrimenti :80 risponde 301 e il probe fallisce) sono
# dichiarati in README.md.
cloud_ready_http() {
  local response_file
  local status
  validate_cloud_probe_config
  response_file="$(mktemp "$(runtime_dir)/cloud-ready.XXXXXX")"
  if ! status="$(curl --fail --silent --show-error \
    --connect-timeout "${CLOUD_CONNECT_TIMEOUT_SECONDS:-5}" \
    --max-time "${CLOUD_HEALTHCHECK_TIMEOUT_SECONDS:-10}" \
    --connect-to \
    "${HELPDESK_FQDN}:80:${CLOUD_TARGET_HOST}:${CLOUD_TARGET_PORT:-80}" \
    --output "${response_file}" \
    --write-out '%{http_code}' \
    "http://${HELPDESK_FQDN}${CLOUD_HEALTHCHECK_PATH:-/health/ready}")"; then
    rm -f "${response_file}"
    return 1
  fi
  if [ "${status}" != "200" ] ||
    ! grep -Eq '"status"[[:space:]]*:[[:space:]]*"ready"' "${response_file}" ||
    ! grep -Eq '"service"[[:space:]]*:[[:space:]]*"helios-bff"' "${response_file}"; then
    rm -f "${response_file}"
    return 1
  fi
  rm -f "${response_file}"
}

cloud_ready() {
  case "${CLOUD_PROBE_MODE:-lxc-k3s}" in
    lxc-k3s) cloud_ready_lxc ;;
    https) cloud_ready_https ;;
    http) cloud_ready_http ;;
    *)
      echo "Unsupported CLOUD_PROBE_MODE: ${CLOUD_PROBE_MODE}" >&2
      return 1
      ;;
  esac
}

onprem_ready() {
  local helios_namespace="${HELIOS_DR_NAMESPACE:-helios-desk}"
  exec_onprem kubectl get --raw \
    "/api/v1/namespaces/${helios_namespace}/services/http:helios-bff:http/proxy/health/ready" \
    >/dev/null
}

wait_for_deployment_pod() {
  local exec_fn="$1"
  local selector="$2"
  local pod

  for _ in $(seq 1 120); do
    pod="$("${exec_fn}" kubectl -n "${APP_NAMESPACE}" get pod -l "${selector}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [ -n "${pod}" ]; then
      printf '%s\n' "${pod}"
      return 0
    fi
    sleep 2
  done

  echo "Pod with selector ${selector} did not appear in namespace ${APP_NAMESPACE}" >&2
  return 1
}

wait_for_pod_running() {
  local exec_fn="$1"
  local pod="$2"
  local phase

  for _ in $(seq 1 120); do
    phase="$("${exec_fn}" kubectl -n "${APP_NAMESPACE}" get pod "${pod}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    if [ "${phase}" = "Running" ]; then
      return 0
    fi
    sleep 2
  done

  echo "Pod ${pod} did not reach Running phase in namespace ${APP_NAMESPACE}" >&2
  return 1
}
