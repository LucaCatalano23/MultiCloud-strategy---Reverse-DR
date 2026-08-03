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
  grep -Eq -- "$1" "$AWS_CALL_LOG" \
    || fail "chiamata AWS attesa non trovata: $1"
}

assert_not_called() {
  if grep -Eq -- "$1" "$AWS_CALL_LOG"; then
    fail "chiamata AWS inattesa trovata: $1"
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
  "ec2 describe-security-groups"*) printf '%s\n' 'sg-nat' ;;
  "ec2 authorize-security-group-ingress"*) ;;
  "ec2 describe-security-group-rules"*)
    if [ "${MOCK_UNEXPECTED_NAT_RULE:-0}" = "1" ]; then
      printf '%s\n' 'sgr-wide'
    else
      printf '%s\n' 'None'
    fi
    ;;
  "ec2 describe-instances"*"instance-state-name"*) printf '%s\n' 'i-nat' ;;
  "ec2 describe-instances"*"State.Name"*) printf '%s\n' "$MOCK_NAT_STATE" ;;
  "ec2 start-instances"*) ;;
  "ec2 wait instance-running"*) ;;
  "ec2 wait instance-stopped"*) ;;
  "ec2 wait instance-status-ok"*) ;;
  "ec2 modify-instance-attribute"*) ;;
  "ec2 describe-addresses"*"AllocationId"*) printf '%s\n' 'eipalloc-test' ;;
  "ec2 describe-addresses"*"InstanceId"*) printf '%s\n' 'i-nat' ;;
  "ec2 associate-address"*) ;;
  "ec2 describe-route-tables"*"tag:Name"*) printf '%s\n' 'rtb-private' ;;
  "ec2 describe-route-tables"*"association.subnet-id"*"RouteTableId"*) printf '%s\n' 'rtb-other' ;;
  "ec2 describe-route-tables"*"association.subnet-id"*"RouteTableAssociationId"*) printf '%s\n' 'rtbassoc-old' ;;
  "ec2 describe-route-tables"*"Routes"*) printf '%s\n' 'i-old blackhole' ;;
  "ec2 replace-route"*) ;;
  "ec2 create-route"*) ;;
  "ec2 replace-route-table-association"*) ;;
  "ec2 associate-route-table"*) ;;
  *)
    printf 'chiamata AWS non simulata: %s\n' "$*" >&2
    exit 98
    ;;
esac
MOCK_AWS
  chmod +x "${mock_bin}/aws"
}

run_function() {
  local function_name="$1" nat_state="$2" case_dir="${TEST_ROOT}/$3"
  local mock_bin="${case_dir}/bin"
  mkdir -p "${case_dir}/state"
  make_mock_aws "$mock_bin"
  AWS_CALL_LOG="${case_dir}/aws-calls.log" \
  MOCK_NAT_STATE="$nat_state" \
  MOCK_UNEXPECTED_NAT_RULE="${MOCK_UNEXPECTED_NAT_RULE:-0}" \
  PATH="${mock_bin}:$PATH" \
  STATE_DIR="${case_dir}/state" \
  VPC_ID="vpc-test" \
  PUB_PRIMARY_SUBNET="subnet-public" \
  PRIV_PRIMARY_SUBNET="subnet-private" \
  NAT_INSTANCE="i-nat" \
    bash "$PROVISION_SCRIPT" "$function_name" >/dev/null
  AWS_CALL_LOG="${case_dir}/aws-calls.log"
}

run_function_fails() {
  local function_name="$1" nat_state="$2" case_dir="${TEST_ROOT}/$3"
  local mock_bin="${case_dir}/bin"
  mkdir -p "${case_dir}/state"
  make_mock_aws "$mock_bin"
  if AWS_CALL_LOG="${case_dir}/aws-calls.log" \
      MOCK_NAT_STATE="$nat_state" \
      MOCK_UNEXPECTED_NAT_RULE="${MOCK_UNEXPECTED_NAT_RULE:-0}" \
      PATH="${mock_bin}:$PATH" \
      STATE_DIR="${case_dir}/state" \
      VPC_ID="vpc-test" \
      PUB_PRIMARY_SUBNET="subnet-public" \
      PRIV_PRIMARY_SUBNET="subnet-private" \
      NAT_INSTANCE="i-nat" \
      bash "$PROVISION_SCRIPT" "$function_name" >"${case_dir}/output.log" 2>&1; then
    fail "${function_name} doveva fallire"
  fi
  AWS_CALL_LOG="${case_dir}/aws-calls.log"
  OUTPUT_LOG="${case_dir}/output.log"
}

test_stopped_nat_is_started_and_reconciled() {
  run_function _nat_instance stopped stopped_nat
  assert_called '^ec2 start-instances '
  assert_called '^ec2 wait instance-running '
  assert_called '^ec2 modify-instance-attribute .*--no-source-dest-check'
  assert_called '^ec2 wait instance-status-ok '
  assert_called '^ec2 authorize-security-group-ingress '
  assert_not_called '^ec2 run-instances '
  assert_not_called '^ec2 associate-address '
}

test_private_route_and_association_are_reconciled() {
  run_function _private_route_table running private_route
  assert_called '^ec2 replace-route .*--destination-cidr-block 0.0.0.0/0 --instance-id i-nat'
  assert_called '^ec2 replace-route-table-association --association-id rtbassoc-old --route-table-id rtb-private'
  assert_not_called '^ec2 create-route-table '
}

test_unexpected_nat_ingress_fails_closed() {
  MOCK_UNEXPECTED_NAT_RULE=1 run_function_fails _nat_instance running broad_nat_ingress
  grep -q 'ingress inattese' "$OUTPUT_LOG" \
    || fail "diagnostica per ingress NAT inattese non trovata"
  assert_not_called '^ec2 describe-instances '
}

test_stopped_nat_is_started_and_reconciled
test_private_route_and_association_are_reconciled
test_unexpected_nat_ingress_fails_closed

printf 'PASS: provision-cli network reconciliation\n'
