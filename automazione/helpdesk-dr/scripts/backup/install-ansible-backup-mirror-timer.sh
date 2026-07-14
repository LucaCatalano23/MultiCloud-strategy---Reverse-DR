#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/../common/lib.sh"

require_ansible_coordinator

cat >/etc/systemd/system/helpdesk-backup-mirror.service <<EOF
[Unit]
Description=Mirror LocalStack S3 backups outside the cloud failure domain
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=${ROOT_DIR}
ExecStart=/bin/bash ${ROOT_DIR}/scripts/backup/sync-backups-onprem.sh
EOF

cat >/etc/systemd/system/helpdesk-backup-mirror.timer <<EOF
[Unit]
Description=Mirror Helpdesk S3 backups every ${BACKUP_MIRROR_INTERVAL_MINUTES} minutes

[Timer]
OnCalendar=*:5/${BACKUP_MIRROR_INTERVAL_MINUTES}
Persistent=true
RandomizedDelaySec=0
Unit=helpdesk-backup-mirror.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now helpdesk-backup-mirror.timer

echo "Installed Ansible backup mirror timer every ${BACKUP_MIRROR_INTERVAL_MINUTES} minutes."

