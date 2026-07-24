#!/usr/bin/env bash
# Registra nel database applicativo una metrica DR verificabile dalla dashboard.
#
# Perche' esiste: fino a ieri il BFF esponeva `rpoMinutes` letto da una variabile
# d'ambiente statica, cioe' un numero deciso a mano che non dimostrava nulla. Le
# metriche mostrate in dashboard devono venire da chi l'evento lo ha davvero
# eseguito: il CronJob di backup per l'RPO, questo script (chiamato da
# failover.yml) per l'RTO del playbook.
#
# Il valore scritto qui e' la durata dell'orchestrazione Ansible - restore,
# preflight identita', promozione dei workload, switch DNS - e NON include il
# tempo di rilevamento del guasto: la dashboard lo dichiara esplicitamente.
#
# Uso:
#   record-dr-telemetry.sh <metric> <duration_seconds|-> [detail_json]
set -euo pipefail

METRIC="${1:?metric name required}"
DURATION="${2:?duration seconds or - required}"
DETAIL="${3:-{\}}"

KUBECTL_BIN="${KUBECTL:-kubectl}"
NAMESPACE="${HELIOS_DR_NAMESPACE:-helios-desk}"
DB_SECRET="${HELIOS_DB_SECRET:-helios-app-database}"
PSQL_IMAGE="${PSQL_IMAGE:-postgres:16-alpine}"
JOB_NAME="helios-dr-telemetry"

if [ "${DURATION}" = "-" ]; then
  DURATION_SQL="NULL"
else
  case "${DURATION}" in
    ''|*[!0-9]*)
      echo "Durata non numerica: ${DURATION}" >&2
      exit 1
      ;;
  esac
  DURATION_SQL="${DURATION}"
fi

if ! "${KUBECTL_BIN}" -n "${NAMESPACE}" get secret "${DB_SECRET}" >/dev/null 2>&1; then
  echo "Secret ${NAMESPACE}/${DB_SECRET} non trovato: telemetria DR non registrata." >&2
  exit 1
fi

"${KUBECTL_BIN}" -n "${NAMESPACE}" delete job "${JOB_NAME}" --ignore-not-found >/dev/null

"${KUBECTL_BIN}" -n "${NAMESPACE}" apply -f - >/dev/null <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: helios-dr-telemetry
    app.kubernetes.io/part-of: helios-desk
spec:
  backoffLimit: 1
  ttlSecondsAfterFinished: 300
  template:
    metadata:
      labels:
        app.kubernetes.io/name: helios-dr-telemetry
    spec:
      restartPolicy: Never
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
        runAsGroup: 65534
      containers:
        - name: record
          image: ${PSQL_IMAGE}
          command: ["/bin/sh", "-c"]
          args:
            - |
              set -eu
              url="\$(printf '%s' "\$DATABASE_URL" | sed 's#^postgresql+asyncpg:#postgresql:#')"
              psql "\$url" -v ON_ERROR_STOP=1 \
                -v metric="${METRIC}" \
                -v detail='${DETAIL}' <<'SQL'
              INSERT INTO dr_telemetry (metric, recorded_at, duration_seconds, detail)
              VALUES (:'metric', now(), ${DURATION_SQL}, :'detail'::jsonb)
              ON CONFLICT (metric) DO UPDATE
                SET recorded_at = EXCLUDED.recorded_at,
                    duration_seconds = EXCLUDED.duration_seconds,
                    detail = EXCLUDED.detail;
              SQL
              echo "Telemetria DR registrata: ${METRIC}"
          env:
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: ${DB_SECRET}
                  key: DATABASE_URL
YAML

if ! "${KUBECTL_BIN}" -n "${NAMESPACE}" wait --for=condition=complete "job/${JOB_NAME}" --timeout=60s >/dev/null 2>&1; then
  echo "Registrazione telemetria DR non completata. Log:" >&2
  "${KUBECTL_BIN}" -n "${NAMESPACE}" logs "job/${JOB_NAME}" >&2 || true
  exit 1
fi

echo "Telemetria DR '${METRIC}' registrata nel database applicativo."
