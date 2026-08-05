#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/../common/lib.sh"

require_ansible_coordinator

mode="${1:-${DR_CONTROLLER_MODE:-watch}}"
failure_threshold="${DR_CONTROLLER_FAILURE_THRESHOLD:-3}"
success_threshold="${DR_CONTROLLER_SUCCESS_THRESHOLD:-2}"
interval="${DR_CONTROLLER_INTERVAL_SECONDS:-20}"
retry_cooldown="${DR_CONTROLLER_RETRY_COOLDOWN_SECONDS:-300}"
controller_lock="$(runtime_dir)/controller.lock"

is_positive_integer() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

is_non_negative_integer() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

validate_dr_controller_config() {
  case "${mode}" in
    watch | oneshot | validate) ;;
    *)
      echo "DR controller mode must be watch, oneshot or validate." >&2
      return 1
      ;;
  esac
  if [ "${DR_AUTO_FAILOVER_ENABLED:-false}" != "true" ]; then
    echo "DR_AUTO_FAILOVER_ENABLED must be true after the cloud probe target has been verified." >&2
    return 1
  fi
  is_positive_integer "${failure_threshold}" || {
    echo "DR_CONTROLLER_FAILURE_THRESHOLD must be a positive integer." >&2
    return 1
  }
  is_positive_integer "${success_threshold}" || {
    echo "DR_CONTROLLER_SUCCESS_THRESHOLD must be a positive integer." >&2
    return 1
  }
  is_positive_integer "${interval}" || {
    echo "DR_CONTROLLER_INTERVAL_SECONDS must be a positive integer." >&2
    return 1
  }
  is_non_negative_integer "${retry_cooldown}" || {
    echo "DR_CONTROLLER_RETRY_COOLDOWN_SECONDS must be a non-negative integer." >&2
    return 1
  }
  validate_cloud_probe_config
  case "$(read_dr_state)" in
    primary | dr) ;;
    *)
      echo "DR state must be explicitly initialized and not require reconciliation." >&2
      return 1
      ;;
  esac
}

acquire_lock() {
  exec 9>"${controller_lock}"
  if ! flock -n 9; then
    echo "Another DR controller is already running: ${controller_lock}" >&2
    return 1
  fi
}

trigger_failover() {
  local current_state
  current_state="$(read_dr_state)"
  case "${current_state}" in
    primary) ;;
    dr)
      echo "Primary is down, but DR state is already active. No action."
      return 0
      ;;
    promoting)
      echo "DR state is promoting; refusing a second automatic restore." >&2
      return 1
      ;;
    *)
      echo "Unknown DR state: ${current_state}" >&2
      return 1
      ;;
  esac

  echo "Primary failed health threshold. Running the Ansible failover playbook..."
  bash "${SCRIPT_DIR}/run-ansible-failover.sh"
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
      if ! trigger_failover; then
        echo "Automatic failover failed; retrying after ${retry_cooldown}s." >&2
        if [ "${retry_cooldown}" -gt 0 ]; then
          sleep "${retry_cooldown}"
        fi
      fi
      failures=0
    fi

    sleep "${interval}"
  done
}

validate_dr_controller_config
if [ "${mode}" = "validate" ]; then
  echo "Automatic DR controller configuration is valid and armed."
  exit 0
fi
acquire_lock
if [ "${mode}" = "oneshot" ]; then
  if cloud_ready; then
    echo "primary ready; no failover required"
  else
    echo "primary not ready; running one-shot DR evaluation"
    trigger_failover
  fi
  exit 0
fi

watch_loop
