#!/usr/bin/env bash
# Applica lo schema della generazione corrente (helios) al database dedicato
# indicato dal Secret `helios-app-database` (chiave DATABASE_URL) nel namespace
# helios-desk.
#
# Perche' esiste: le immagini dei servizi (ticket-service, bff, automation) NON
# eseguono migrazioni all'avvio (nessun initContainer/entrypoint di migrazione,
# vedi i Dockerfile). Lo schema va quindi applicato esplicitamente a un database
# dedicato, distinto dal monolite legacy `helpdesk`. Le migrazioni usano
# CREATE TABLE IF NOT EXISTS, quindi questo script e' idempotente e sicuro da
# rieseguire. Vedi CLAUDE.md §1 e la guardia in create-secrets.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_SERVICES_DIR="$(cd "${SCRIPT_DIR}/../../../apps/backend/services" && pwd)"
KUBECTL_BIN="${KUBECTL:-kubectl}"
NAMESPACE="helios-desk"
DB_SECRET="helios-app-database"
MIGRATIONS_CONFIGMAP="helios-db-migrations"
MIGRATE_JOB="helios-db-migrate"
PSQL_IMAGE="${PSQL_IMAGE:-postgres:16-alpine}"

# Ordine lessicale del prefisso = ordine di applicazione. I servizi non hanno
# dipendenze incrociate a livello di tabella, ma il prefisso mantiene un ordine
# deterministico e leggibile.
declare -a MIGRATION_FILES=(
  "10-ticket-service=${BACKEND_SERVICES_DIR}/ticket-service/migrations/001_initial.sql"
  "20-bff=${BACKEND_SERVICES_DIR}/bff/migrations/001_initial.sql"
  "30-automation-service=${BACKEND_SERVICES_DIR}/automation-service/migrations/001_initial.sql"
)

if ! "${KUBECTL_BIN}" -n "${NAMESPACE}" get secret "${DB_SECRET}" >/dev/null 2>&1; then
  echo "Secret ${NAMESPACE}/${DB_SECRET} non trovato: esegui prima create-secrets.sh." >&2
  exit 1
fi

configmap_args=()
for entry in "${MIGRATION_FILES[@]}"; do
  key="${entry%%=*}"
  path="${entry#*=}"
  if [ ! -r "${path}" ]; then
    echo "File di migrazione mancante: ${path}" >&2
    exit 1
  fi
  configmap_args+=("--from-file=${key}.sql=${path}")
done

echo "Riconciliazione ConfigMap ${NAMESPACE}/${MIGRATIONS_CONFIGMAP}..."
"${KUBECTL_BIN}" -n "${NAMESPACE}" create configmap "${MIGRATIONS_CONFIGMAP}" \
  "${configmap_args[@]}" \
  --dry-run=client --output=yaml | "${KUBECTL_BIN}" apply -f - >/dev/null

echo "Rimozione eventuale Job precedente ${NAMESPACE}/${MIGRATE_JOB}..."
"${KUBECTL_BIN}" -n "${NAMESPACE}" delete job "${MIGRATE_JOB}" --ignore-not-found >/dev/null

echo "Applicazione migrazioni via Job ${NAMESPACE}/${MIGRATE_JOB} (immagine ${PSQL_IMAGE})..."
"${KUBECTL_BIN}" -n "${NAMESPACE}" apply -f - >/dev/null <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: ${MIGRATE_JOB}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: helios-db-migrate
    app.kubernetes.io/part-of: helios-desk
spec:
  backoffLimit: 2
  ttlSecondsAfterFinished: 300
  template:
    metadata:
      labels:
        app.kubernetes.io/name: helios-db-migrate
    spec:
      restartPolicy: Never
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
        runAsGroup: 65534
      containers:
        - name: migrate
          image: ${PSQL_IMAGE}
          command: ["/bin/sh", "-c"]
          args:
            - |
              set -eu
              # psql non accetta lo schema SQLAlchemy postgresql+asyncpg://
              url="\$(printf '%s' "\$DATABASE_URL" | sed 's#^postgresql+asyncpg:#postgresql:#')"
              for f in \$(ls /migrations/*.sql | sort); do
                echo "== applico \$f =="
                psql "\$url" -v ON_ERROR_STOP=1 -f "\$f"
              done
              echo "Migrazioni applicate."
          env:
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: ${DB_SECRET}
                  key: DATABASE_URL
          volumeMounts:
            - name: migrations
              mountPath: /migrations
              readOnly: true
      volumes:
        - name: migrations
          configMap:
            name: ${MIGRATIONS_CONFIGMAP}
YAML

echo "Attesa completamento Job..."
if ! "${KUBECTL_BIN}" -n "${NAMESPACE}" wait --for=condition=complete "job/${MIGRATE_JOB}" --timeout=120s >/dev/null 2>&1; then
  echo "Job non completato. Log:" >&2
  "${KUBECTL_BIN}" -n "${NAMESPACE}" logs "job/${MIGRATE_JOB}" >&2 || true
  exit 1
fi

"${KUBECTL_BIN}" -n "${NAMESPACE}" logs "job/${MIGRATE_JOB}"
echo "Schema helios applicato al database dedicato."
