#!/bin/sh
set -eu

if [ "${LAMBDA_DR_FORCE_RIE:-}" = "1" ]; then
  exec /usr/local/bin/aws-lambda-rie /lambda-entrypoint.sh "$@"
fi

if [ -n "${AWS_LAMBDA_RUNTIME_API:-}" ]; then
  exec /lambda-entrypoint.sh "$@"
fi

exec /usr/local/bin/aws-lambda-rie /lambda-entrypoint.sh "$@"
