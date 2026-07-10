#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/../common/lib.sh"

mode="${1:-${DR_CONTROLLER_MODE:-watch}}"
failure_threshold="${DR_CONTROLLER_FAILURE_THRESHOLD:-3}"
success_threshold="${DR_CONTROLLER_SUCCESS_THRESHOLD:-2}"
interval="${DR_CONTROLLER_INTERVAL_SECONDS:-20}"
lock_dir="${ROOT_DIR}/.state/dr-controller.lock"

acquire_lock() {
  mkdir -p "$(state_dir)"
  if mkdir "${lock_dir}" 2>/dev/null; then
    trap 'rmdir "${lock_dir}" 2>/dev/null || true' EXIT
    return 0
  fi
  echo "Another DR controller is already running: ${lock_dir}" >&2
  return 1
}

trigger_failover() {
  local current_state
  current_state="$(read_dr_state)"
  if [ "${current_state}" = "dr" ]; then
    echo "Primary is down, but DR state is already active. No action."
    return 0
  fi

  echo "Primary failed health threshold. Running failover playbook..."
  bash "${SCRIPT_DIR}/failover-to-onprem.sh"
}

watch_loop() {
  local failures=0
  local successes=0
  local recovery_notified=0

  while true; do
    if cloud_ready; then
      successes=$((successes + 1))
      failures=0
      echo "primary ready (${successes}/${success_threshold})"
      if [ "${successes}" -ge "${success_threshold}" ] && [ "$(read_dr_state)" = "dr" ] && [ "${recovery_notified}" -eq 0 ]; then
        echo "Primary recovered while DR is active. Cutback is intentionally manual to avoid data loss."
        recovery_notified=1
      fi
    else
      failures=$((failures + 1))
      successes=0
      recovery_notified=0
      echo "primary not ready (${failures}/${failure_threshold})"
    fi

    if [ "${failures}" -ge "${failure_threshold}" ]; then
      trigger_failover
      if [ "${mode}" = "oneshot" ]; then
        return 0
      fi
      failures=0
    fi

    if [ "${mode}" = "oneshot" ]; then
      return 0
    fi

    sleep "${interval}"
  done
}

acquire_lock
watch_loop
