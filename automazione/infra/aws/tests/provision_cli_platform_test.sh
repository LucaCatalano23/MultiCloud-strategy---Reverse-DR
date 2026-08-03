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

make_mock_kubectl() {
  local mock_bin="$1"
  mkdir -p "$mock_bin"
  cat >"${mock_bin}/kubectl" <<'MOCK_KUBECTL'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"$KUBECTL_CALL_LOG"
case "$*" in
  "get nodes -o name"*)
    [ "$MOCK_NODE_COUNT" = "0" ] || printf '%s\n' 'node/ip-10-42-10-10'
    ;;
  "wait --for=condition=Ready nodes --all"*)
    [ "$MOCK_NODES_READY" = "1" ]
    ;;
  "get nodes -o wide"*)
    printf '%s\n' 'ip-10-42-10-10 NotReady'
    ;;
  *)
    printf 'chiamata kubectl non simulata: %s\n' "$*" >&2
    exit 98
    ;;
esac
MOCK_KUBECTL
  chmod +x "${mock_bin}/kubectl"
}

run_ready_check() {
  local node_count="$1" ready="$2" expected="$3" case_dir="${TEST_ROOT}/$4"
  local mock_bin="${case_dir}/bin"
  mkdir -p "${case_dir}/state"
  make_mock_kubectl "$mock_bin"
  set +e
  KUBECTL_CALL_LOG="${case_dir}/kubectl-calls.log" \
  MOCK_NODE_COUNT="$node_count" \
  MOCK_NODES_READY="$ready" \
  PATH="${mock_bin}:$PATH" \
  STATE_DIR="${case_dir}/state" \
    bash "$PROVISION_SCRIPT" _ensure_cluster_nodes_ready \
      >"${case_dir}/output.log" 2>&1
  local rc=$?
  set -e
  if [ "$expected" = "success" ] && [ "$rc" -ne 0 ]; then
    fail "il controllo nodi doveva riuscire"
  fi
  if [ "$expected" = "failure" ] && [ "$rc" -eq 0 ]; then
    fail "il controllo nodi doveva fallire"
  fi
  KUBECTL_CALL_LOG="${case_dir}/kubectl-calls.log"
  OUTPUT_LOG="${case_dir}/output.log"
}

test_no_nodes_fails_before_wait() {
  run_ready_check 0 0 failure no_nodes
  grep -q 'Nessun nodo EKS registrato' "$OUTPUT_LOG" \
    || fail "diagnostica per node group assente non trovata"
  if grep -q '^wait ' "$KUBECTL_CALL_LOG"; then
    fail "kubectl wait non deve partire senza nodi"
  fi
}

test_ready_nodes_succeed() {
  run_ready_check 1 1 success ready
  grep -q '^wait --for=condition=Ready nodes --all ' "$KUBECTL_CALL_LOG" \
    || fail "attesa Ready non eseguita"
}

test_not_ready_nodes_show_diagnostics() {
  run_ready_check 1 0 failure not_ready
  grep -q '^get nodes -o wide$' "$KUBECTL_CALL_LOG" \
    || fail "diagnostica dei nodi NotReady non eseguita"
  grep -q 'non sono Ready' "$OUTPUT_LOG" \
    || fail "messaggio per nodi NotReady non trovato"
}

test_no_nodes_fails_before_wait
test_ready_nodes_succeed
test_not_ready_nodes_show_diagnostics

printf 'PASS: provision-cli platform readiness\n'
