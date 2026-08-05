#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROVISION_SCRIPT="${SCRIPT_DIR}/../provision-cli/provision.sh"
README_FILE="${SCRIPT_DIR}/../provision-cli/README.md"
CHECKLIST_FILE="${SCRIPT_DIR}/../provision-cli/CHECKLIST_RISORSE_AWS.md"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_absent() {
  local pattern="$1" file="$2"
  if grep -Eq -- "$pattern" "$file"; then
    fail "pattern CloudWatch inatteso in ${file}: ${pattern}"
  fi
}

assert_present() {
  local pattern="$1" file="$2"
  grep -Eq -- "$pattern" "$file" \
    || fail "pattern atteso non trovato in ${file}: ${pattern}"
}

# Il provisioning non deve creare log group né concedere alla Lambda permessi
# di scrittura su CloudWatch Logs.
assert_absent '^[[:space:]]*aws logs ' "$PROVISION_SCRIPT"
assert_absent 'EKS_LOG_TYPES|LOG_RETENTION_DAYS' "$PROVISION_SCRIPT"
assert_present 'detach-role-policy' "$PROVISION_SCRIPT"
basic_policy_refs=$(grep -c 'AWSLambdaBasicExecutionRole' "$PROVISION_SCRIPT")
[ "$basic_policy_refs" -eq 1 ] \
  || fail "AWSLambdaBasicExecutionRole deve comparire solo nella rimozione idempotente"

# Sia i cluster nuovi sia quelli già esistenti devono convergere con tutti i
# cinque tipi di log del control plane disabilitati.
assert_present 'update-cluster-config' "$PROVISION_SCRIPT"
for log_type in api audit authenticator controllerManager scheduler; do
  assert_present "${log_type}" "$PROVISION_SCRIPT"
done

# La documentazione operativa non deve chiedere di creare risorse CloudWatch.
assert_absent 'Create log group|creare.*log group|create-log-group' "$README_FILE"
assert_absent 'Create log group|Creazione manuale: CloudWatch' "$CHECKLIST_FILE"

make_mock_aws() {
  local mock_bin="$1"
  mkdir -p "$mock_bin"
  cat >"${mock_bin}/aws" <<'MOCK_AWS'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"$AWS_CALL_LOG"
case "$*" in
  "eks describe-cluster"*)
    printf '%s\n' "$MOCK_ENABLED_TYPES"
    ;;
  "eks update-cluster-config"*|"eks wait cluster-active"*)
    ;;
  *)
    printf 'chiamata AWS non simulata: %s\n' "$*" >&2
    exit 98
    ;;
esac
MOCK_AWS
  chmod +x "${mock_bin}/aws"
}

run_disable_logs() {
  local enabled_types="$1" case_name="$2"
  local case_dir="${TEST_ROOT}/${case_name}" mock_bin="${TEST_ROOT}/${case_name}/bin"
  mkdir -p "${case_dir}/state"
  make_mock_aws "$mock_bin"
  : >"${case_dir}/aws-calls.log"
  AWS_CALL_LOG="${case_dir}/aws-calls.log" \
  MOCK_ENABLED_TYPES="$enabled_types" \
  PATH="${mock_bin}:$PATH" \
  STATE_DIR="${case_dir}/state" \
    bash "$PROVISION_SCRIPT" _disable_eks_control_plane_logs >/dev/null
  AWS_CALL_LOG="${case_dir}/aws-calls.log"
}

run_disable_logs "" already_disabled
if grep -q '^eks update-cluster-config ' "$AWS_CALL_LOG"; then
  fail "un cluster già senza log non deve essere aggiornato"
fi

run_disable_logs "authenticator" enabled
assert_present '^eks update-cluster-config .*enabled=false' "$AWS_CALL_LOG"
for log_type in api audit authenticator controllerManager scheduler; do
  assert_present "$log_type" "$AWS_CALL_LOG"
done
assert_present '^eks wait cluster-active ' "$AWS_CALL_LOG"

make_mock_iam_aws() {
  local mock_bin="$1"
  mkdir -p "$mock_bin"
  cat >"${mock_bin}/aws" <<'MOCK_AWS'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"$AWS_CALL_LOG"
case "$MOCK_DETACH_RESULT" in
  success)
    exit 0
    ;;
  not_found)
    printf '%s\n' 'An error occurred (NoSuchEntity) when calling DetachRolePolicy' >&2
    exit 254
    ;;
  access_denied)
    printf '%s\n' 'An error occurred (AccessDenied) when calling DetachRolePolicy' >&2
    exit 254
    ;;
esac
MOCK_AWS
  chmod +x "${mock_bin}/aws"
}

run_detach_policy() {
  local result="$1" expected="$2" case_dir="${TEST_ROOT}/detach-${1}"
  local mock_bin="${case_dir}/bin"
  mkdir -p "${case_dir}/state"
  make_mock_iam_aws "$mock_bin"
  : >"${case_dir}/aws-calls.log"
  set +e
  AWS_CALL_LOG="${case_dir}/aws-calls.log" \
  MOCK_DETACH_RESULT="$result" \
  PATH="${mock_bin}:$PATH" \
  STATE_DIR="${case_dir}/state" \
    bash "$PROVISION_SCRIPT" _detach_managed_policy_if_attached \
      test-role arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole \
      >"${case_dir}/output.log" 2>&1
  local rc=$?
  set -e
  if [ "$expected" = success ] && [ "$rc" -ne 0 ]; then
    fail "la rimozione idempotente della policy doveva riuscire: $result"
  fi
  if [ "$expected" = failure ] && [ "$rc" -eq 0 ]; then
    fail "un errore IAM reale non deve essere ignorato: $result"
  fi
}

run_detach_policy success success
run_detach_policy not_found success
run_detach_policy access_denied failure

printf 'PASS: provision-cli does not provision CloudWatch Logs\n'
