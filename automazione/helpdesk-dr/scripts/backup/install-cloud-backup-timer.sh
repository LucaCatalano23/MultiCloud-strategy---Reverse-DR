#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/../common/lib.sh"

copy_to_container "${CLOUD_K3S_NAME}" "${ROOT_DIR}" "/opt/helpdesk-dr"
endpoint="$(discover_localstack_endpoint exec_cloud)"

exec_cloud install -d -m 0750 /etc/helpdesk-dr
exec_cloud bash -lc "cat >/etc/helpdesk-dr/backup.env" <<EOF
LOCALSTACK_ENDPOINT=${endpoint}
BACKUP_S3_BUCKET=${BACKUP_S3_BUCKET}
BACKUP_S3_PREFIX=${BACKUP_S3_PREFIX}
AWS_REGION=${AWS_REGION}
AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}
EOF
exec_cloud chmod 0600 /etc/helpdesk-dr/backup.env

exec_cloud bash -lc "cat >/etc/systemd/system/helpdesk-cloud-backup.service" <<EOF
[Unit]
Description=Helpdesk cloud primary backup

[Service]
Type=oneshot
WorkingDirectory=/opt/helpdesk-dr
EnvironmentFile=/etc/helpdesk-dr/backup.env
ExecStart=/bin/bash /opt/helpdesk-dr/scripts/backup/cloud-local-backup.sh
EOF

exec_cloud bash -lc "cat >/etc/systemd/system/helpdesk-cloud-backup.timer" <<EOF
[Unit]
Description=Run helpdesk cloud backup every ${BACKUP_INTERVAL_MINUTES} minutes

[Timer]
OnCalendar=*:0/${BACKUP_INTERVAL_MINUTES}
Persistent=true
RandomizedDelaySec=0
Unit=helpdesk-cloud-backup.service

[Install]
WantedBy=timers.target
EOF

exec_cloud systemctl daemon-reload
exec_cloud systemctl enable --now helpdesk-cloud-backup.timer
echo "Installed cloud backup timer every ${BACKUP_INTERVAL_MINUTES} minutes."
