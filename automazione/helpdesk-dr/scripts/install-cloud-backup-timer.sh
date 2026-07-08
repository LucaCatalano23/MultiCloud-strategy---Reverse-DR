#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

copy_to_container "${CLOUD_K3S_NAME}" "${ROOT_DIR}" "/opt/helpdesk-dr"

exec_cloud bash -lc "cat >/etc/systemd/system/helpdesk-cloud-backup.service" <<EOF
[Unit]
Description=Helpdesk cloud primary backup

[Service]
Type=oneshot
WorkingDirectory=/opt/helpdesk-dr
ExecStart=/bin/bash /opt/helpdesk-dr/scripts/cloud-local-backup.sh
EOF

exec_cloud bash -lc "cat >/etc/systemd/system/helpdesk-cloud-backup.timer" <<EOF
[Unit]
Description=Run helpdesk cloud backup every ${BACKUP_INTERVAL_MINUTES} minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=${BACKUP_INTERVAL_MINUTES}min
Unit=helpdesk-cloud-backup.service

[Install]
WantedBy=timers.target
EOF

exec_cloud systemctl daemon-reload
exec_cloud systemctl enable --now helpdesk-cloud-backup.timer
echo "Installed cloud backup timer every ${BACKUP_INTERVAL_MINUTES} minutes."
