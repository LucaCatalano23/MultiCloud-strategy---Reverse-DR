#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temp_dir="$(mktemp -d)"
trap 'rm -rf "${temp_dir}"' EXIT

export TERNA_DR_CONFIG_FILE="${temp_dir}/config.env"
mkdir -p "${temp_dir}/bin"
cat >"${TERNA_DR_CONFIG_FILE}" <<EOF
TERNA_DR_AUTO_FAILOVER_ENABLED=true
TERNA_CONTROLLER_FAILURE_THRESHOLD=2
TERNA_CONTROLLER_INTERVAL_SECONDS=120
TERNA_CONTROLLER_STATE_DIR=${temp_dir}/state
TERNA_PRIMARY_PROBE_URL=https://www.terna.it/
TERNA_PUBLIC_DNS_RESOLVER=10.10.4.2
TERNA_DNS_TARGET_IP=10.10.3.10
TERNA_STATIC_HEALTH_URL=http://terna.it/health
EOF

cat >"${temp_dir}/bin/hostname" <<'EOF'
#!/usr/bin/env bash
echo ansible-node
EOF
cat >"${temp_dir}/bin/lxc" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >>"${TERNA_TEST_LXC_LOG}"
if [ "$1" = list ]; then printf '%s\n' "$2"; fi
EOF
cat >"${temp_dir}/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${TERNA_TEST_CURL_LOG}"
case " $* " in
  *' --resolve terna.it:80:10.10.3.10 '*) exit "${TERNA_TEST_STATIC_CURL_RESULT:-0}" ;;
esac
exit "${TERNA_TEST_CURL_RESULT:-1}"
EOF
cat >"${temp_dir}/bin/dig" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${TERNA_TEST_DIG_LOG}"
printf '%s\n' "${TERNA_TEST_PUBLIC_IP:-192.0.2.10}"
EOF
cat >"${temp_dir}/bin/ansible-playbook" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${TERNA_TEST_PLAYBOOK_LOG}"
exit "${TERNA_TEST_PLAYBOOK_RESULT:-0}"
EOF
cat >"${temp_dir}/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit "${TERNA_TEST_SLEEP_RESULT:-0}"
EOF
chmod +x "${temp_dir}/bin/hostname" "${temp_dir}/bin/lxc" "${temp_dir}/bin/curl" "${temp_dir}/bin/dig" "${temp_dir}/bin/ansible-playbook" "${temp_dir}/bin/sleep"
export TERNA_TEST_LXC_LOG="${temp_dir}/lxc.log"
export TERNA_TEST_CURL_LOG="${temp_dir}/curl.log"
export TERNA_TEST_DIG_LOG="${temp_dir}/dig.log"
export TERNA_TEST_PLAYBOOK_LOG="${temp_dir}/playbook.log"

PATH="${temp_dir}/bin:${PATH}" TERNA_TEST_CURL_RESULT=1 bash "${ROOT_DIR}/bin/lxc-lab-controller.sh" oneshot
grep -Fx '+short @10.10.4.2 www.terna.it A' "${TERNA_TEST_DIG_LOG}" >/dev/null
grep -F -- '--resolve www.terna.it:443:192.0.2.10' "${TERNA_TEST_CURL_LOG}" >/dev/null
if test -e "${TERNA_TEST_PLAYBOOK_LOG}"; then
  echo 'DNS was changed after one failed probe.' >&2
  exit 1
fi
PATH="${temp_dir}/bin:${PATH}" TERNA_TEST_CURL_RESULT=1 bash "${ROOT_DIR}/bin/lxc-lab-controller.sh" oneshot
grep -F 'terna-static-dr-failover.yml' "${TERNA_TEST_PLAYBOOK_LOG}" >/dev/null
grep -F 'dns_target_ip=10.10.3.10' "${TERNA_TEST_PLAYBOOK_LOG}" >/dev/null
grep -F -- '--resolve terna.it:80:10.10.3.10' "${TERNA_TEST_CURL_LOG}" >/dev/null
grep -F '.load-chart-placeholder-v1' "${TERNA_TEST_LXC_LOG}" >/dev/null

failover_count="$(wc -l <"${TERNA_TEST_PLAYBOOK_LOG}" | tr -d ' ')"
PATH="${temp_dir}/bin:${PATH}" TERNA_TEST_CURL_RESULT=0 bash "${ROOT_DIR}/bin/lxc-lab-controller.sh" oneshot
test "$(wc -l <"${TERNA_TEST_PLAYBOOK_LOG}" | tr -d ' ')" = "${failover_count}"

# A failed playbook in watch mode must not be reported or persisted as a
# successful failover. Calling a function from `... || true` suppresses Bash's
# errexit inside that function, so this protects the controller explicitly.
printf '%s\n' primary >"${temp_dir}/state/mode"
printf '%s\n' 1 >"${temp_dir}/state/failures"
set +e
failure_output="$(
  PATH="${temp_dir}/bin:${PATH}" \
    TERNA_TEST_CURL_RESULT=1 \
    TERNA_TEST_PLAYBOOK_RESULT=42 \
    TERNA_TEST_SLEEP_RESULT=99 \
    bash "${ROOT_DIR}/bin/lxc-lab-controller.sh" watch 2>&1
)"
failure_status=$?
set -e
test "${failure_status}" -ne 0
test "$(cat "${temp_dir}/state/mode")" = primary
if grep -Fq 'Lab DNS now resolves' <<<"${failure_output}"; then
  echo 'Controller reported a successful DNS failover after Ansible failed.' >&2
  exit 1
fi

echo 'LXC lab controller behavior test passed.'
