#!/bin/sh
set -eu

case "${HELIOS_API_BASE_PATH}" in
  /*) ;;
  *) echo "HELIOS_API_BASE_PATH must be a same-origin absolute path" >&2; exit 1 ;;
esac

if printf '%s' "${HELIOS_API_BASE_PATH}" | grep -Eq '(^//|\\|\.\.|[?#])'; then
  echo "HELIOS_API_BASE_PATH contains forbidden characters" >&2
  exit 1
fi

case "${HELIOS_DEMO_MODE}" in
  true|false) ;;
  *) echo "HELIOS_DEMO_MODE must be true or false" >&2; exit 1 ;;
esac

if ! printf '%s' "${HELIOS_CSRF_COOKIE_NAME}" | grep -Eq '^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$'; then
  echo "HELIOS_CSRF_COOKIE_NAME is invalid" >&2
  exit 1
fi

if ! printf '%s' "${HELIOS_CSRF_HEADER_NAME}" | grep -Eq '^[A-Za-z0-9-]{1,64}$'; then
  echo "HELIOS_CSRF_HEADER_NAME is invalid" >&2
  exit 1
fi

export HELIOS_API_BASE_PATH HELIOS_DEMO_MODE HELIOS_CSRF_COOKIE_NAME HELIOS_CSRF_HEADER_NAME
output_path='/usr/share/nginx/html/config/runtime-config.json'
temporary_path="${output_path}.tmp.$$"
umask 027
envsubst '${HELIOS_API_BASE_PATH} ${HELIOS_DEMO_MODE} ${HELIOS_CSRF_COOKIE_NAME} ${HELIOS_CSRF_HEADER_NAME}' \
  < /opt/helios/runtime-config.json.template \
  > "${temporary_path}"
mv "${temporary_path}" "${output_path}"
