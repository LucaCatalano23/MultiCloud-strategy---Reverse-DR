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

apply_helpdesk_runtime_secrets() {
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

  if [ -n "${AWS_ACCESS_KEY_ID:-}" ] && [ -n "${AWS_SECRET_ACCESS_KEY:-}" ]; then
    "${executor}" sh -c '
      set -eu
      kubectl -n "$1" create secret generic helpdesk-aws \
        --from-literal=AWS_ACCESS_KEY_ID="$2" \
        --from-literal=AWS_SECRET_ACCESS_KEY="$3" \
        --dry-run=client -o yaml | kubectl apply -f -
    ' sh "${APP_NAMESPACE}" "${AWS_ACCESS_KEY_ID}" "${AWS_SECRET_ACCESS_KEY}"
  fi
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

localstack_endpoint() {
  if [ -n "${LOCALSTACK_ENDPOINT:-}" ]; then
    printf '%s\n' "${LOCALSTACK_ENDPOINT}"
    return 0
  fi
  if [ -s /etc/helpdesk-dr/localstack.endpoint ]; then
    cat /etc/helpdesk-dr/localstack.endpoint
    return 0
  fi
  printf 'http://%s:4566\n' "$(lxd_host_gateway)"
}

discover_localstack_endpoint() {
  local exec_fn="$1"
  local candidate ip
  local candidates=("$(lxd_host_gateway)")

  if [ -s /etc/helpdesk-dr/localstack.endpoint ]; then
    ip="$(sed -E 's#^https?://([^:/]+).*#\1#' /etc/helpdesk-dr/localstack.endpoint)"
    if [ -n "${ip}" ]; then
      candidates=("${ip}" "${candidates[@]}")
    fi
  fi

  ip="$(ip -4 route show default 2>/dev/null | awk 'NR == 1 { print $3 }')"
  if [ -n "${ip}" ]; then
    candidates+=("${ip}")
  fi
  ip="$(getent ahostsv4 host.docker.internal 2>/dev/null | awk 'NR == 1 { print $1 }')"
  if [ -n "${ip}" ]; then
    candidates+=("${ip}")
  fi

  for candidate in "${candidates[@]}"; do
    if "${exec_fn}" curl -fsS --max-time 3 "http://${candidate}:4566/_localstack/health" >/dev/null 2>&1; then
      printf 'http://%s:4566\n' "${candidate}"
      return 0
    fi
  done

  echo "LocalStack is not reachable from the target LXD node." >&2
  return 1
}

install_aws_cli_v2() {
  local exec_fn="$1"
  local existing_version machine_arch installer_arch installer_name installer_url

  # The probe always exits successfully so an expected "not installed" result
  # does not trigger lxc_retry's infrastructure-failure backoff.
  existing_version="$("${exec_fn}" sh -lc 'if command -v aws >/dev/null 2>&1; then aws --version 2>&1; fi')"
  if [[ "${existing_version}" == aws-cli/2.* ]]; then
    if [ "${AWS_CLI_VERSION:-latest}" = "latest" ] ||
      [[ "${existing_version}" == "aws-cli/${AWS_CLI_VERSION} "* ]]; then
      printf '%s\n' "${existing_version}"
      return 0
    fi
  fi

  machine_arch="$("${exec_fn}" uname -m)"
  case "${machine_arch}" in
    x86_64|amd64)
      installer_arch="x86_64"
      ;;
    aarch64|arm64)
      installer_arch="aarch64"
      ;;
    *)
      echo "AWS CLI v2 is not supported by this installer on architecture: ${machine_arch}" >&2
      return 1
      ;;
  esac

  installer_name="awscli-exe-linux-${installer_arch}"
  if [ "${AWS_CLI_VERSION:-latest}" = "latest" ]; then
    installer_url="https://awscli.amazonaws.com/${installer_name}.zip"
  else
    installer_url="https://awscli.amazonaws.com/${installer_name}-${AWS_CLI_VERSION}.zip"
  fi

  echo "Installing AWS CLI v2 from the official AWS installer (${installer_arch})..."
  "${exec_fn}" bash -s -- "${installer_url}" <<'AWS_CLI_INSTALL'
set -euo pipefail

installer_url="$1"
work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT

curl --fail --location \
  --retry 5 \
  --retry-delay 2 \
  --connect-timeout 15 \
  "${installer_url}" \
  --output "${work_dir}/awscliv2.zip"
unzip -q "${work_dir}/awscliv2.zip" -d "${work_dir}"

install_args=(
  --bin-dir /usr/local/bin
  --install-dir /usr/local/aws-cli
)
if [ -x /usr/local/aws-cli/v2/current/bin/aws ]; then
  install_args+=(--update)
fi

"${work_dir}/aws/install" "${install_args[@]}"
/usr/local/bin/aws --version
AWS_CLI_INSTALL
}

aws_local() {
  AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}" \
  AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}" \
  AWS_DEFAULT_REGION="${AWS_REGION:-eu-west-1}" \
    aws --endpoint-url "$(localstack_endpoint)" "$@"
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
auth IN A ${ONPREM_K3S_IP}
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
  probe_cloud curl -fsS -H "Host: ${HELPDESK_FQDN}" "http://127.0.0.1/health/ready" >/dev/null
}

onprem_ready() {
  local helios_namespace="${HELIOS_DR_NAMESPACE:-helios-desk}"
  if exec_onprem kubectl -n "${helios_namespace}" get deployment/helios-bff >/dev/null 2>&1; then
    exec_onprem kubectl get --raw \
      "/api/v1/namespaces/${helios_namespace}/services/http:helios-bff:http/proxy/health/ready" \
      >/dev/null
    return
  fi
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
