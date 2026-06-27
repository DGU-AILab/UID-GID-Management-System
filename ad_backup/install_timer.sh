#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="${AD_BACKUP_SERVICE_NAME:-decs-ad-backup}"
ON_CALENDAR="${AD_BACKUP_ON_CALENDAR:-*-*-* 03:30:00}"
UNIT_DIR="/etc/systemd/system"

command -v systemctl >/dev/null 2>&1 || {
  echo "systemctl is required" >&2
  exit 1
}

sudo -n tee "$UNIT_DIR/$SERVICE_NAME.service" >/dev/null <<EOF
[Unit]
Description=Back up DECS Samba AD DC state
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=$(id -un)
Group=$(id -gn)
WorkingDirectory=$SCRIPT_DIR
ExecStart=$SCRIPT_DIR/backup_ad.sh
EOF

sudo -n tee "$UNIT_DIR/$SERVICE_NAME.timer" >/dev/null <<EOF
[Unit]
Description=Run DECS Samba AD backup daily

[Timer]
OnCalendar=$ON_CALENDAR
Persistent=true
Unit=$SERVICE_NAME.service

[Install]
WantedBy=timers.target
EOF

sudo -n systemctl daemon-reload
sudo -n systemctl enable --now "$SERVICE_NAME.timer"
systemctl list-timers "$SERVICE_NAME.timer" --no-pager
