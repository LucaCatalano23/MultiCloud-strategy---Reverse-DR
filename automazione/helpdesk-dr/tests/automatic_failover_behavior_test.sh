#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${TEST_DIR}/.." && pwd)"
temp_dir="$(mktemp -d)"
trap 'rm -rf "${temp_dir}"' EXIT

cat >"${temp_dir}/config.env" <<EOF
POSTGRES_PASSWORD=test-only
DR_REQUIRE_ANSIBLE_NODE=false
DR_STATE_DIR=${temp_dir}/state
DR_RUNTIME_DIR=${temp_dir}/run
EOF
export HELPDESK_DR_CONFIG_FILE="${temp_dir}/config.env"

# shellcheck source=../scripts/common/lib.sh
source "${ROOT_DIR}/scripts/common/lib.sh"

[ "$(read_dr_state)" = unknown ]

CLOUD_PROBE_MODE=https
CLOUD_TARGET_HOST=k8s-helios-test.eu-west-1.elb.amazonaws.com
CLOUD_TARGET_PORT=443
CLOUD_HEALTHCHECK_PATH=/health/ready
CLOUD_CONNECT_TIMEOUT_SECONDS=3
CLOUD_HEALTHCHECK_TIMEOUT_SECONDS=5
DR_AUTO_FAILOVER_ENABLED=true
capture_file="${temp_dir}/curl-args"

curl() {
  local previous=''
  local output_file=''
  printf '%s\n' "$@" >"${capture_file}"
  for argument in "$@"; do
    if [ "${previous}" = '--output' ]; then
      output_file="${argument}"
      break
    fi
    previous="${argument}"
  done
  printf '{"status":"ready","service":"helios-bff"}\n' >"${output_file}"
  printf '200'
}

cloud_ready_https
grep -Fx -- '--connect-to' "${capture_file}" >/dev/null
grep -Fx -- \
  'heliospoc.terna.it:443:k8s-helios-test.eu-west-1.elb.amazonaws.com:443' \
  "${capture_file}" >/dev/null
grep -Fx -- 'https://heliospoc.terna.it/health/ready' "${capture_file}" >/dev/null
# Con un cert fidato il probe non deve rilassare la verifica TLS.
if grep -Fxq -- '--insecure' "${capture_file}" || grep -Fxq -- '--cacert' "${capture_file}"; then
  echo 'Strict https probe must not relax TLS verification.' >&2
  exit 1
fi

# Self-signed via --insecure (salta la verifica).
CLOUD_TARGET_INSECURE=true
cloud_ready_https
grep -Fx -- '--insecure' "${capture_file}" >/dev/null
if grep -Fxq -- '--cacert' "${capture_file}"; then
  echo 'Insecure probe must not also pin a CA.' >&2
  exit 1
fi
CLOUD_TARGET_INSECURE=false

# Self-signed via CA pinnata (--cacert).
ca_file="${temp_dir}/alb-ca.crt"
printf 'dummy-ca\n' >"${ca_file}"
CLOUD_TARGET_CA_FILE="${ca_file}"
cloud_ready_https
grep -Fx -- '--cacert' "${capture_file}" >/dev/null
grep -Fx -- "${ca_file}" "${capture_file}" >/dev/null
if grep -Fxq -- '--insecure' "${capture_file}"; then
  echo 'CA-pinned probe must not skip verification.' >&2
  exit 1
fi

# I due knob TLS sono mutuamente esclusivi.
CLOUD_TARGET_INSECURE=true
if validate_cloud_probe_config >/dev/null 2>&1; then
  echo 'Mutually exclusive TLS knobs were accepted together.' >&2
  exit 1
fi
CLOUD_TARGET_INSECURE=false

# Una CA pinnata inesistente deve far fallire la validazione.
CLOUD_TARGET_CA_FILE="${temp_dir}/missing-ca.crt"
if validate_cloud_probe_config >/dev/null 2>&1; then
  echo 'Missing CA file was accepted.' >&2
  exit 1
fi
CLOUD_TARGET_CA_FILE=""

# Probe HTTP verso l'IP diretto dell'ALB (scenario senza ACM): stesso Host
# canonico via --connect-to, ma schema http e porta 80.
CLOUD_PROBE_MODE=http
CLOUD_TARGET_HOST=203.0.113.10
CLOUD_TARGET_PORT=80
cloud_ready_http
grep -Fx -- '--connect-to' "${capture_file}" >/dev/null
grep -Fx -- 'heliospoc.terna.it:80:203.0.113.10:80' "${capture_file}" >/dev/null
grep -Fx -- 'http://heliospoc.terna.it/health/ready' "${capture_file}" >/dev/null

# Ripristina lo scenario https per i controlli di validazione seguenti.
CLOUD_PROBE_MODE=https
CLOUD_TARGET_HOST=k8s-helios-test.eu-west-1.elb.amazonaws.com
CLOUD_TARGET_PORT=443

CLOUD_TARGET_HOST='invalid target'
if validate_cloud_probe_config >/dev/null 2>&1; then
  echo 'Invalid ALB target hostname was accepted.' >&2
  exit 1
fi

CLOUD_TARGET_HOST=k8s-helios-test.eu-west-1.elb.amazonaws.com
CLOUD_CONNECT_TIMEOUT_SECONDS=invalid
if validate_cloud_probe_config >/dev/null 2>&1; then
  echo 'Invalid cloud connect timeout was accepted.' >&2
  exit 1
fi
CLOUD_CONNECT_TIMEOUT_SECONDS=3
CLOUD_HEALTHCHECK_TIMEOUT_SECONDS=0
if validate_cloud_probe_config >/dev/null 2>&1; then
  echo 'Zero cloud healthcheck timeout was accepted.' >&2
  exit 1
fi
CLOUD_HEALTHCHECK_TIMEOUT_SECONDS=5

DR_AUTO_FAILOVER_ENABLED=false
if bash "${ROOT_DIR}/scripts/failover/dr-controller.sh" validate \
  >"${temp_dir}/not-armed.log" 2>&1; then
  echo 'An unarmed automatic controller was accepted.' >&2
  exit 1
fi
grep -F 'DR_AUTO_FAILOVER_ENABLED must be true' "${temp_dir}/not-armed.log" >/dev/null
DR_AUTO_FAILOVER_ENABLED=true

cat >>"${temp_dir}/config.env" <<EOF
DR_CONTROLLER_FAILURE_THRESHOLD=0
CLOUD_PROBE_MODE=lxc-k3s
DR_AUTO_FAILOVER_ENABLED=true
EOF
if bash "${ROOT_DIR}/scripts/failover/dr-controller.sh" oneshot \
  >"${temp_dir}/invalid-threshold.log" 2>&1; then
  echo 'Zero failure threshold was accepted.' >&2
  exit 1
fi
grep -F 'DR_CONTROLLER_FAILURE_THRESHOLD must be a positive integer.' \
  "${temp_dir}/invalid-threshold.log" >/dev/null

write_dr_state primary
[ "$(read_dr_state)" = primary ]
[ -f "${temp_dir}/state/updated_at" ]

echo 'Automatic failover behavior tests passed.'
