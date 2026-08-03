#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROVISION_SCRIPT="${SCRIPT_DIR}/../provision-cli/provision.sh"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_called() {
  local pattern="$1"
  grep -Eq -- "$pattern" "$AWS_CALL_LOG" \
    || fail "chiamata AWS attesa non trovata: $pattern"
}

assert_not_called() {
  local pattern="$1"
  if grep -Eq -- "$pattern" "$AWS_CALL_LOG"; then
    fail "chiamata AWS inattesa trovata: $pattern"
  fi
}

make_mock_aws() {
  local mock_bin="$1"
  mkdir -p "$mock_bin"
  cat >"${mock_bin}/aws" <<'MOCK_AWS'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"$AWS_CALL_LOG"

case "$*" in
  "ec2 describe-launch-templates"*)
    printf '%s\n' 'lt-test123'
    ;;
  "eks describe-nodegroup"*)
    if [ "$MOCK_NODEGROUP_STATUS" = "ABSENT" ]; then
      printf '%s\n' 'ResourceNotFoundException: node group not found' >&2
      exit 254
    fi
    if [ "$MOCK_NODEGROUP_STATUS" = "ACCESS_DENIED" ]; then
      printf '%s\n' 'AccessDeniedException: not authorized' >&2
      exit 254
    fi
    if [[ "$*" == *"nodegroup.status"* ]]; then
      printf '%s\n' "$MOCK_NODEGROUP_STATUS"
    elif [[ "$*" == *"nodegroup.health.issues"* ]]; then
      printf '%s\n' 'NodeCreationFailure Nodes failed to join the cluster i-test123'
    fi
    ;;
  "eks create-nodegroup"*)
    ;;
  "eks delete-nodegroup"*)
    ;;
  "eks wait nodegroup-active"*)
    if [ "${MOCK_WAITER_FAIL:-0}" = "1" ]; then
      printf '%s\n' 'Waiter NodegroupActive failed' >&2
      exit 255
    fi
    ;;
  "eks wait nodegroup-deleted"*)
    ;;
  *)
    fail "chiamata AWS non simulata: $*"
    ;;
esac
MOCK_AWS
  chmod +x "${mock_bin}/aws"
}

run_node_group() {
  local status="$1" case_dir="${TEST_ROOT}/$2"
  local mock_bin="${case_dir}/bin"
  mkdir -p "${case_dir}/state"
  make_mock_aws "$mock_bin"
  AWS_CALL_LOG="${case_dir}/aws-calls.log" \
  MOCK_NODEGROUP_STATUS="$status" \
  MOCK_WAITER_FAIL="${MOCK_WAITER_FAIL:-0}" \
  PATH="${mock_bin}:$PATH" \
  STATE_DIR="${case_dir}/state" \
  ACCOUNT_ID="123456789012" \
  PRIV_PRIMARY_SUBNET="subnet-primary" \
    bash "$PROVISION_SCRIPT" _node_group >/dev/null
  AWS_CALL_LOG="${case_dir}/aws-calls.log"
}

run_node_group_fails() {
  local status="$1" case_dir="${TEST_ROOT}/$2"
  local mock_bin="${case_dir}/bin"
  mkdir -p "${case_dir}/state"
  make_mock_aws "$mock_bin"
  if AWS_CALL_LOG="${case_dir}/aws-calls.log" \
      MOCK_NODEGROUP_STATUS="$status" \
      MOCK_WAITER_FAIL="${MOCK_WAITER_FAIL:-0}" \
      PATH="${mock_bin}:$PATH" \
      STATE_DIR="${case_dir}/state" \
      ACCOUNT_ID="123456789012" \
      PRIV_PRIMARY_SUBNET="subnet-primary" \
      bash "$PROVISION_SCRIPT" _node_group >"${case_dir}/output.log" 2>&1; then
    fail "_node_group doveva fallire per lo stato ${status}"
  fi
  AWS_CALL_LOG="${case_dir}/aws-calls.log"
}

test_active_is_a_noop() {
  run_node_group ACTIVE active
  assert_not_called '^eks create-nodegroup '
  assert_not_called '^eks delete-nodegroup '
  assert_not_called '^eks wait nodegroup-active '
}

test_creating_is_resumed() {
  run_node_group CREATING creating
  assert_called '^eks wait nodegroup-active '
  assert_not_called '^eks create-nodegroup '
  assert_not_called '^eks delete-nodegroup '
}

test_absent_is_created() {
  run_node_group ABSENT absent
  assert_called '^eks create-nodegroup '
  assert_called '^eks wait nodegroup-active '
  assert_not_called '^eks delete-nodegroup '
}

test_create_failed_is_recreated() {
  run_node_group CREATE_FAILED create_failed
  assert_called '^eks describe-nodegroup .*nodegroup.health.issues'
  assert_called '^eks delete-nodegroup '
  assert_called '^eks wait nodegroup-deleted '
  assert_called '^eks create-nodegroup '
  assert_called '^eks wait nodegroup-active '
}

test_deleting_is_resumed_then_recreated() {
  run_node_group DELETING deleting
  assert_called '^eks wait nodegroup-deleted '
  assert_called '^eks create-nodegroup '
  assert_called '^eks wait nodegroup-active '
  assert_not_called '^eks delete-nodegroup '
}

test_degraded_is_diagnosed_without_deletion() {
  run_node_group_fails DEGRADED degraded
  assert_called '^eks describe-nodegroup .*nodegroup.health.issues'
  assert_not_called '^eks delete-nodegroup '
  assert_not_called '^eks create-nodegroup '
}

test_waiter_failure_is_diagnosed() {
  MOCK_WAITER_FAIL=1 run_node_group_fails CREATING waiter_failure
  assert_called '^eks wait nodegroup-active '
  assert_called '^eks describe-nodegroup .*nodegroup.health.issues'
  assert_not_called '^eks create-nodegroup '
}

test_describe_error_does_not_create() {
  run_node_group_fails ACCESS_DENIED access_denied
  assert_not_called '^eks create-nodegroup '
  assert_not_called '^eks delete-nodegroup '
}

test_active_is_a_noop
test_creating_is_resumed
test_absent_is_created
test_create_failed_is_recreated
test_deleting_is_resumed_then_recreated
test_degraded_is_diagnosed_without_deletion
test_waiter_failure_is_diagnosed
test_describe_error_does_not_create

printf 'PASS: provision-cli node group state machine\n'
