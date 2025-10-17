#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME=ups_monitor
SRC_SCRIPT="$(dirname "$0")/ups_monitor.py"
DEST_SCRIPT=/usr/local/bin/ups_monitor.py
UNIT_FILE=/etc/systemd/system/${SERVICE_NAME}.service

if [[ $EUID -ne 0 ]]; then
  echo "Veuillez exécuter en root: sudo $0"
  exit 1
fi

echo "Copie du script -> ${DEST_SCRIPT}"
install -m 0755 "$SRC_SCRIPT" "$DEST_SCRIPT"

echo "Installation du fichier unit systemd -> ${UNIT_FILE}"
cat > "${UNIT_FILE}" <<'UNIT'
[Unit]
Description=UPS Monitor (UPS Shield X1200/X1201/X1202)
After=multi-user.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/ups_monitor.py
Restart=on-failure
RestartSec=5
User=root
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

echo "Création dossier logs /var/log/ups_monitor"
mkdir -p /var/log/ups_monitor
chown root:root /var/log/ups_monitor
chmod 0755 /var/log/ups_monitor

echo "Reload systemd, enable et start"
systemctl daemon-reload
systemctl enable --now ${SERVICE_NAME}.service

echo "Fini. Status:"
systemctl status ${SERVICE_NAME}.service --no-pager