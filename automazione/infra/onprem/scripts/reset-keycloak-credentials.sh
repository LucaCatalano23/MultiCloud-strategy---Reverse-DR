#!/usr/bin/env bash
# Reimposta le credenziali Keycloak senza cancellare il realm o il database.
#
# Il recovery admin temporaneo viene creato con il comando ufficiale Keycloak
# 26 mentre il server e' spento. Le nuove credenziali diventano prima fonte di
# verita' in OpenBao, poi ESO aggiorna i Secret Kubernetes e infine l'account
# admin esistente e l'operatore DR vengono riconciliati.
set -euo pipefail
set +x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ONPREM_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
KUBECTL_BIN="${KUBECTL:-kubectl}"
LXC_BIN="${LXC:-lxc}"
NAMESPACE=helios-identity
KEYCLOAK_DEPLOYMENT=keycloak
KEYCLOAK_IMAGE=quay.io/keycloak/keycloak:26.7.0
OPENBAO_NODE="${OPENBAO_NODE:-vault-openbao}"
OPENBAO_KV_MOUNT="${OPENBAO_KV_MOUNT:-helios}"
RECOVERY_SECRET=keycloak-credential-recovery
RECOVERY_JOB=keycloak-credential-recovery
ROTATION_JOB=keycloak-credential-rotation
CLEANUP_JOB=keycloak-credential-cleanup

: "${BAO_TOKEN:?BAO_TOKEN must be exported with an OpenBao write-capable token}"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Required command '$1' is unavailable." >&2
    exit 1
  }
}

require_minimum_length() {
  local label="$1" value="$2"
  if [ "${#value}" -lt 16 ]; then
    echo "${label} must contain at least 16 characters." >&2
    exit 1
  fi
}

read_secret_twice() {
  local label="$1" first second
  read -r -s -p "${label}: " first
  echo
  read -r -s -p "Confirm ${label}: " second
  echo
  if [ "$first" != "$second" ]; then
    echo "The two values do not match." >&2
    exit 1
  fi
  require_minimum_length "$label" "$first"
  REPLY="$first"
}

require_command "${KUBECTL_BIN}"
require_command "${LXC_BIN}"
require_command python3

for secret in keycloak-postgres keycloak-bootstrap-admin helios-dr-operator; do
  "${KUBECTL_BIN}" -n "${NAMESPACE}" get "secret/${secret}" >/dev/null
done
"${LXC_BIN}" info "${OPENBAO_NODE}" >/dev/null

read -r -p "Existing Keycloak admin username [admin-bootstrap]: " NEW_ADMIN_USERNAME
NEW_ADMIN_USERNAME="${NEW_ADMIN_USERNAME:-admin-bootstrap}"
if ! [[ "${NEW_ADMIN_USERNAME}" =~ ^[A-Za-z0-9._-]{3,64}$ ]]; then
  echo "The Keycloak admin username contains unsupported characters." >&2
  exit 1
fi
read_secret_twice "New Keycloak admin password"
NEW_ADMIN_PASSWORD="$REPLY"

read -r -p "DR operator username [dr-operator]: " OPERATOR_USERNAME
OPERATOR_USERNAME="${OPERATOR_USERNAME:-dr-operator}"
if ! [[ "${OPERATOR_USERNAME}" =~ ^[A-Za-z0-9._-]{3,64}$ ]]; then
  echo "The DR operator username contains unsupported characters." >&2
  exit 1
fi
read -r -p "DR operator employee ID: " OPERATOR_EMPLOYEE_ID
if ! [[ "${OPERATOR_EMPLOYEE_ID}" =~ ^[A-Za-z0-9._-]{1,128}$ ]]; then
  echo "The DR operator employee ID contains unsupported characters." >&2
  exit 1
fi
read -r -p "DR operator email: " OPERATOR_EMAIL
if ! [[ "${OPERATOR_EMAIL}" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
  echo "The DR operator email is invalid." >&2
  exit 1
fi
read_secret_twice "New DR operator password"
OPERATOR_PASSWORD="$REPLY"

RECOVERY_USERNAME="credential-recovery-$(date +%s)"
RECOVERY_PASSWORD="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/helios-keycloak-recovery.XXXXXX")"
KEYCLOAK_WAS_SCALED_DOWN=false
ORIGINAL_REPLICAS="$("${KUBECTL_BIN}" -n "${NAMESPACE}" get "deployment/${KEYCLOAK_DEPLOYMENT}" -o jsonpath='{.spec.replicas}')"
if ! [[ "${ORIGINAL_REPLICAS}" =~ ^[0-9]+$ ]]; then
  echo "Unable to determine the existing Keycloak replica count." >&2
  exit 1
fi
REMOTE_FILES=()
REMOTE_SUFFIX="${RANDOM}${RANDOM}"
RECOVERY_ACCOUNT_READY=false
RECOVERY_ACCOUNT_REMOVED=false
RECOVERY_SECRET_CREATED=false
RESET_COMPLETED=false

cleanup() {
  local status=$?
  if [ "${KEYCLOAK_WAS_SCALED_DOWN}" = true ]; then
    "${KUBECTL_BIN}" -n "${NAMESPACE}" scale "deployment/${KEYCLOAK_DEPLOYMENT}" --replicas="${ORIGINAL_REPLICAS}" >/dev/null 2>&1 || true
  fi
  if [ "${RESET_COMPLETED}" = true ]; then
    "${KUBECTL_BIN}" -n "${NAMESPACE}" delete "job/${RECOVERY_JOB}" "job/${ROTATION_JOB}" "job/${CLEANUP_JOB}" \
      --ignore-not-found --wait=false >/dev/null 2>&1 || true
  else
    echo "Recovery Jobs were retained for diagnostics; inspect their logs before the next attempt." >&2
  fi
  if [ "${RECOVERY_ACCOUNT_REMOVED}" = true ] || { [ "${RECOVERY_SECRET_CREATED}" = true ] && [ "${RECOVERY_ACCOUNT_READY}" = false ]; }; then
    "${KUBECTL_BIN}" -n "${NAMESPACE}" delete "secret/${RECOVERY_SECRET}" \
      --ignore-not-found >/dev/null 2>&1 || true
  elif [ "${RECOVERY_ACCOUNT_READY}" = true ]; then
    echo "Recovery admin remains available in secret/${RECOVERY_SECRET}; remove it only after completing manual recovery." >&2
  fi
  if [ "${#REMOTE_FILES[@]}" -gt 0 ]; then
    "${LXC_BIN}" exec "${OPENBAO_NODE}" -- rm -f "${REMOTE_FILES[@]}" >/dev/null 2>&1 || true
  fi
  rm -rf "${WORK_DIR}"
  unset BAO_TOKEN NEW_ADMIN_PASSWORD OPERATOR_PASSWORD RECOVERY_PASSWORD
  exit "${status}"
}
trap cleanup EXIT INT TERM

printf '%s' "${RECOVERY_USERNAME}" >"${WORK_DIR}/recovery-username"
printf '%s' "${RECOVERY_PASSWORD}" >"${WORK_DIR}/recovery-password"
printf '%s' "${NEW_ADMIN_USERNAME}" >"${WORK_DIR}/admin-username"
printf '%s' "${NEW_ADMIN_PASSWORD}" >"${WORK_DIR}/admin-password"
printf '%s' "${OPERATOR_USERNAME}" >"${WORK_DIR}/operator-username"
printf '%s' "${OPERATOR_PASSWORD}" >"${WORK_DIR}/operator-password"
printf '%s' "${OPERATOR_EMPLOYEE_ID}" >"${WORK_DIR}/operator-employee-id"
printf '%s' "${OPERATOR_EMAIL}" >"${WORK_DIR}/operator-email"
printf '%s' "${BAO_TOKEN}" >"${WORK_DIR}/bao-token"
chmod 600 "${WORK_DIR}"/*

"${KUBECTL_BIN}" -n "${NAMESPACE}" delete "job/${RECOVERY_JOB}" "job/${ROTATION_JOB}" "job/${CLEANUP_JOB}" \
  --ignore-not-found --wait=true >/dev/null
"${KUBECTL_BIN}" -n "${NAMESPACE}" delete "secret/${RECOVERY_SECRET}" \
  --ignore-not-found >/dev/null
"${KUBECTL_BIN}" -n "${NAMESPACE}" create secret generic "${RECOVERY_SECRET}" \
  --from-file=username="${WORK_DIR}/recovery-username" \
  --from-file=password="${WORK_DIR}/recovery-password" >/dev/null
RECOVERY_SECRET_CREATED=true

echo "Applying the recovery network policy..."
"${KUBECTL_BIN}" apply -f "${ONPREM_DIR}/identity/network-policies.yaml" >/dev/null

echo "Stopping Keycloak to create a temporary recovery administrator..."
"${KUBECTL_BIN}" -n "${NAMESPACE}" scale "deployment/${KEYCLOAK_DEPLOYMENT}" --replicas=0 >/dev/null
KEYCLOAK_WAS_SCALED_DOWN=true
"${KUBECTL_BIN}" -n "${NAMESPACE}" wait --for=delete pod \
  -l app.kubernetes.io/name=keycloak --timeout=180s

cat <<'EOF' | "${KUBECTL_BIN}" apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: keycloak-credential-recovery
  namespace: helios-identity
  labels:
    app.kubernetes.io/name: helios-identity-provisioner
    app.kubernetes.io/component: identity-recovery
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 600
  template:
    metadata:
      labels:
        app.kubernetes.io/name: helios-identity-provisioner
        app.kubernetes.io/component: identity-recovery
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: recovery
          image: quay.io/keycloak/keycloak:26.7.0
          command:
            - /opt/keycloak/bin/kc.sh
            - bootstrap-admin
            - user
            - --username:env
            - RECOVERY_USERNAME
            - --password:env
            - RECOVERY_PASSWORD
            - --no-prompt
          env:
            - name: KC_DB
              value: postgres
            - name: KC_DB_DATABASE
              valueFrom:
                secretKeyRef:
                  name: keycloak-postgres
                  key: POSTGRES_DB
            - name: KC_DB_URL
              value: jdbc:postgresql://keycloak-postgres.helios-identity.svc.cluster.local:5432/$(KC_DB_DATABASE)
            - name: KC_DB_USERNAME
              valueFrom:
                secretKeyRef:
                  name: keycloak-postgres
                  key: POSTGRES_USER
            - name: KC_DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: keycloak-postgres
                  key: POSTGRES_PASSWORD
            - name: RECOVERY_USERNAME
              valueFrom:
                secretKeyRef:
                  name: keycloak-credential-recovery
                  key: username
            - name: RECOVERY_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: keycloak-credential-recovery
                  key: password
          resources:
            requests:
              cpu: 50m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 768Mi
          securityContext:
            allowPrivilegeEscalation: false
            # bootstrap-admin requires a writable Keycloak image while Quarkus
            # rebuilds transformed-bytecode.jar. This is limited to this
            # short-lived, non-root recovery Job.
            readOnlyRootFilesystem: false
            capabilities:
              drop:
                - ALL
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir:
            medium: Memory
            sizeLimit: 64Mi
EOF

"${KUBECTL_BIN}" -n "${NAMESPACE}" wait --for=condition=complete "job/${RECOVERY_JOB}" --timeout=180s
RECOVERY_ACCOUNT_READY=true

echo "Updating the OpenBao source of truth..."
for file in bao-token admin-username admin-password operator-username operator-password operator-employee-id operator-email; do
  remote_file="/tmp/helios-keycloak-reset-${file}-${REMOTE_SUFFIX}"
  "${LXC_BIN}" file push "${WORK_DIR}/${file}" "${OPENBAO_NODE}${remote_file}" \
    --mode=0600 --uid=0 --gid=0
  REMOTE_FILES+=("${remote_file}")
done

"${LXC_BIN}" exec "${OPENBAO_NODE}" -- sh -ceu '
  export BAO_ADDR=https://127.0.0.1:8200
  export BAO_CACERT=/etc/openbao/tls/tls.crt
  export BAO_TOKEN="$(cat /tmp/helios-keycloak-reset-bao-token-$1)"
  bao kv patch -mount="$2" onprem/identity/keycloak-bootstrap-admin \
    username=@/tmp/helios-keycloak-reset-admin-username-$1 \
    password=@/tmp/helios-keycloak-reset-admin-password-$1 >/dev/null
  bao kv patch -mount="$2" onprem/identity/dr-operator \
    username=@/tmp/helios-keycloak-reset-operator-username-$1 \
    password=@/tmp/helios-keycloak-reset-operator-password-$1 \
    employee_id=@/tmp/helios-keycloak-reset-operator-employee-id-$1 \
    email=@/tmp/helios-keycloak-reset-operator-email-$1 >/dev/null
' sh "${REMOTE_SUFFIX}" "${OPENBAO_KV_MOUNT}"

for external_secret in keycloak-bootstrap-admin helios-dr-operator; do
  previous_resource_version="$("${KUBECTL_BIN}" -n "${NAMESPACE}" get "secret/${external_secret}" -o jsonpath='{.metadata.resourceVersion}')"
  "${KUBECTL_BIN}" -n "${NAMESPACE}" annotate "ExternalSecret/${external_secret}" \
    "force-sync=$(date +%s)" --overwrite >/dev/null
  "${KUBECTL_BIN}" -n "${NAMESPACE}" wait --for=condition=Ready \
    "ExternalSecret/${external_secret}" --timeout=120s
  for _ in $(seq 1 60); do
    current_resource_version="$("${KUBECTL_BIN}" -n "${NAMESPACE}" get "secret/${external_secret}" -o jsonpath='{.metadata.resourceVersion}')"
    if [ "${current_resource_version}" != "${previous_resource_version}" ]; then
      break
    fi
    sleep 2
  done
  if [ "${current_resource_version}" = "${previous_resource_version}" ]; then
    echo "External Secrets did not update secret/${external_secret} after the forced sync." >&2
    exit 1
  fi
done

echo "Restarting Keycloak and changing the original administrator password..."
"${KUBECTL_BIN}" -n "${NAMESPACE}" scale "deployment/${KEYCLOAK_DEPLOYMENT}" --replicas="${ORIGINAL_REPLICAS}" >/dev/null
KEYCLOAK_WAS_SCALED_DOWN=false
"${KUBECTL_BIN}" -n "${NAMESPACE}" rollout status "deployment/${KEYCLOAK_DEPLOYMENT}" --timeout=600s

cat <<'EOF' | "${KUBECTL_BIN}" apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: keycloak-credential-rotation
  namespace: helios-identity
  labels:
    app.kubernetes.io/name: helios-identity-provisioner
    app.kubernetes.io/component: identity-recovery
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 600
  template:
    metadata:
      labels:
        app.kubernetes.io/name: helios-identity-provisioner
        app.kubernetes.io/component: identity-recovery
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: rotation
          image: quay.io/keycloak/keycloak:26.7.0
          command:
            - /bin/bash
            - -ec
            - |
              umask 077
              config_file=$(mktemp /tmp/kcadm.XXXXXX)
              trap 'rm -f "$config_file"' EXIT
              kcadm=/opt/keycloak/bin/kcadm.sh
              server=http://keycloak.helios-identity.svc.cluster.local:8080
              "$kcadm" config credentials --config "$config_file" --server "$server" --realm master --user "$RECOVERY_USERNAME" --password "$RECOVERY_PASSWORD" >/dev/null
              admin_id=$("$kcadm" get users --config "$config_file" -r master -q exact=true -q "username=$TARGET_ADMIN_USERNAME" --fields id | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
              test -n "$admin_id"
              "$kcadm" set-password --config "$config_file" -r master --userid "$admin_id" --new-password "$TARGET_ADMIN_PASSWORD" --temporary=false >/dev/null
              "$kcadm" config credentials --config "$config_file" --server "$server" --realm master --user "$TARGET_ADMIN_USERNAME" --password "$TARGET_ADMIN_PASSWORD" >/dev/null
          env:
            - name: RECOVERY_USERNAME
              valueFrom:
                secretKeyRef:
                  name: keycloak-credential-recovery
                  key: username
            - name: RECOVERY_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: keycloak-credential-recovery
                  key: password
            - name: TARGET_ADMIN_USERNAME
              valueFrom:
                secretKeyRef:
                  name: keycloak-bootstrap-admin
                  key: username
            - name: TARGET_ADMIN_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: keycloak-bootstrap-admin
                  key: password
          resources:
            requests:
              cpu: 50m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 512Mi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir:
            medium: Memory
            sizeLimit: 32Mi
EOF

"${KUBECTL_BIN}" -n "${NAMESPACE}" wait --for=condition=complete "job/${ROTATION_JOB}" --timeout=180s
bash "${SCRIPT_DIR}/provision-dr-operator.sh"

cat <<'EOF' | "${KUBECTL_BIN}" apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: keycloak-credential-cleanup
  namespace: helios-identity
  labels:
    app.kubernetes.io/name: helios-identity-provisioner
    app.kubernetes.io/component: identity-recovery
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 600
  template:
    metadata:
      labels:
        app.kubernetes.io/name: helios-identity-provisioner
        app.kubernetes.io/component: identity-recovery
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: cleanup
          image: quay.io/keycloak/keycloak:26.7.0
          command:
            - /bin/bash
            - -ec
            - |
              umask 077
              config_file=$(mktemp /tmp/kcadm.XXXXXX)
              trap 'rm -f "$config_file"' EXIT
              kcadm=/opt/keycloak/bin/kcadm.sh
              server=http://keycloak.helios-identity.svc.cluster.local:8080
              "$kcadm" config credentials --config "$config_file" --server "$server" --realm master --user "$TARGET_ADMIN_USERNAME" --password "$TARGET_ADMIN_PASSWORD" >/dev/null
              recovery_id=$("$kcadm" get users --config "$config_file" -r master -q exact=true -q "username=$RECOVERY_USERNAME" --fields id | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
              test -n "$recovery_id"
              "$kcadm" delete "users/$recovery_id" --config "$config_file" -r master >/dev/null
          env:
            - name: RECOVERY_USERNAME
              valueFrom:
                secretKeyRef:
                  name: keycloak-credential-recovery
                  key: username
            - name: TARGET_ADMIN_USERNAME
              valueFrom:
                secretKeyRef:
                  name: keycloak-bootstrap-admin
                  key: username
            - name: TARGET_ADMIN_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: keycloak-bootstrap-admin
                  key: password
          resources:
            requests:
              cpu: 50m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 512Mi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir:
            medium: Memory
            sizeLimit: 32Mi
EOF
"${KUBECTL_BIN}" -n "${NAMESPACE}" wait --for=condition=complete "job/${CLEANUP_JOB}" --timeout=180s
RECOVERY_ACCOUNT_REMOVED=true

echo "Credential reset completed. Store the new administrator and DR operator credentials in the approved password manager."
RESET_COMPLETED=true
