#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../config.env
source "${ROOT_DIR}/config.env"

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

ensure_container_started() {
  local container="$1"

  if container_running "${container}"; then
    return 0
  fi

  lxc_retry start "${container}" || true
  for _ in $(seq 1 60); do
    if container_running "${container}"; then
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

exec_onprem() {
  ensure_onprem_network_started
  ensure_container_started "${ONPREM_K3S_NAME}"
  lxc_retry exec "${ONPREM_K3S_NAME}" -- "$@"
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

state_dir() {
  mkdir -p "${ROOT_DIR}/.state"
  printf '%s\n' "${ROOT_DIR}/.state"
}

write_dr_state() {
  local state="$1"
  local dir
  dir="$(state_dir)"
  printf '%s\n' "${state}" >"${dir}/mode"
  date -u +"%Y-%m-%dT%H:%M:%SZ" >"${dir}/updated_at"
}

read_dr_state() {
  local dir
  dir="$(state_dir)"
  if [ -f "${dir}/mode" ]; then
    cat "${dir}/mode"
  else
    printf 'primary\n'
  fi
}

wait_for_k3s() {
  local target="$1"
  local exec_fn="$2"

  echo "Waiting for k3s on ${target}..."
  for _ in $(seq 1 120); do
    if "${exec_fn}" kubectl get nodes >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  echo "k3s did not become ready on ${target}" >&2
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

render_dns_zone() {
  local target_ip="$1"
  local serial
  serial="$(date +%s)"
  cat <<EOF
\$TTL 30
@ IN SOA server-dns.${LAB_DOMAIN}. admin.${LAB_DOMAIN}. (
  ${serial} 30 15 604800 30
)
@ IN NS server-dns.${LAB_DOMAIN}.
server-dns IN A ${DNS_SERVER_IP}
helpdesk IN A ${target_ip}
git-server IN A ${GIT_SERVER_IP}
cloud-helpdesk IN A ${CLOUD_K3S_IP}
onprem-helpdesk IN A ${ONPREM_K3S_IP}
EOF
}

set_helpdesk_dns() {
  local target_ip="$1"
  render_dns_zone "${target_ip}" >"${ROOT_DIR}/.helpdesk.zone"
  exec_dns bash -lc "grep -q 'zone \"${LAB_DOMAIN}\"' /etc/bind/named.conf.local || cat >>/etc/bind/named.conf.local <<'EOF'
zone \"${LAB_DOMAIN}\" {
  type master;
  file \"/etc/bind/db.${LAB_DOMAIN}\";
};
EOF"
  lxc_retry file push "${ROOT_DIR}/.helpdesk.zone" "${DNS_SERVER_NAME}/etc/bind/db.${LAB_DOMAIN}"
  exec_dns named-checkconf
  exec_dns named-checkzone "${LAB_DOMAIN}" "/etc/bind/db.${LAB_DOMAIN}"
  exec_dns systemctl restart named
  rm -f "${ROOT_DIR}/.helpdesk.zone"
}

cloud_ready() {
  exec_cloud curl -fsS -H "Host: ${HELPDESK_FQDN}" "http://127.0.0.1/health/ready" >/dev/null
}

onprem_ready() {
  exec_onprem curl -fsS -H "Host: ${HELPDESK_FQDN}" "http://127.0.0.1/health/ready" >/dev/null
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
