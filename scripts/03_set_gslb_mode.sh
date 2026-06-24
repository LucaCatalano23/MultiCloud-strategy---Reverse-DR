#!/usr/bin/env bash
set -Eeuo pipefail

MODE="${1:-}"
CONTROL_DIR="${GSLB_CONTROL_DIR:-/var/lib/gslb-control}"

case "${MODE}" in
  auto|production|dr) ;;
  *)
    echo "Uso: $0 auto|production|dr" >&2
    exit 64
    ;;
esac

printf '%s\n' "${MODE}" >"${CONTROL_DIR}/override.tmp"
mv "${CONTROL_DIR}/override.tmp" "${CONTROL_DIR}/override"
echo "Modalità GSLB impostata su ${MODE}."
