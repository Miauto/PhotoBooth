#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME=watch_print_disable
DEST_SCRIPT=/usr/local/bin/watch_print_disable.sh
UNIT_FILE=/etc/systemd/system/${SERVICE_NAME}.service

# Usage:
# sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Miauto/PhotoBooth/refs/heads/main/scripts/install_watch_print_disable.sh)"
# Ce script installe un service systemd qui surveille l'état de l'imprimante Canon SELPHY CP1500 via CUPS.
#
# Voici les commandes utiles après l'installation :
# systemctl status watch_print_disable
# journalctl -u watch_print_disable -f
#
# Ce script surveille l'état de l'imprimante Canon SELPHY CP1500 via CUPS.
# Si l'imprimante est désactivée à cause de consommables (ex: plus de papier), il tente de la réactiver automatiquement.
# Si elle est désactivée pour une autre raison, il ne fait rien et attend la prochaine vérification.

if [[ $EUID -ne 0 ]]; then
  echo "Ce script doit être exécuté en root. Réessayez avec sudo:"
  echo "  sudo bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Miauto/PhotoBooth/refs/heads/main/scripts/install_watch_print_disable.sh)\""
  exit 1
fi

echo "Installation du script WatchPrintDisable -> ${DEST_SCRIPT}"
cat > "${DEST_SCRIPT}" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

PRN="${1:-Canon-SELPHY-CP1500}"   # Nom exact de la file CUPS

# Récupère état détaillé
STATE="$(lpstat -l -p "$PRN" 2>/dev/null || true)"

# Si l'imprimante n'existe pas :
if [[ -z "$STATE" ]]; then
  logger -t cp1500 "WARN: imprimante '$PRN' introuvable"
  exit 0
fi

# Si elle n'est PAS désactivée/pausée, on sort
if ! echo "$STATE" | grep -qiE "disabled|paused"; then
  exit 0
fi

# Extraire les "Alerts" / "State Reasons"
REASONS_RAW="$(echo "$STATE" | awk -F': ' '/Alerts|State Reasons/ {print tolower($2)}' | tr -d ' ')"
REASONS="${REASONS_RAW:-unknown}"

# Motifs de réactivation automatique (consommables)
if echo "$REASONS" | grep -qE "(media-empty|marker-supply-empty|marker-supply-low|no-paper|no-paper-tray)"; then
  logger -t cp1500 "Auto-heal: '$PRN' désactivée à cause de consommables ($REASONS) — réactivation."
  # Réactiver + réaccepter
  if cupsenable "$PRN" && cupsaccept "$PRN"; then
    logger -t cp1500 "Auto-heal: réactivation OK pour '$PRN'"
    exit 0
  else
    logger -t cp1500 "Auto-heal: ERREUR de réactivation pour '$PRN'"
    exit 1
  fi
else
  logger -t cp1500 "Auto-heal: '$PRN' désactivée pour raison non-consommables ($REASONS) — pas d'action."
fi
BASH
chmod 0755 "${DEST_SCRIPT}"

# install a oneshot service unit (timer will trigger it periodically)
echo "Installation du fichier service -> ${UNIT_FILE}"
cat > "${UNIT_FILE}" <<'UNIT'
[Unit]
Description=Watch Print Disable - Canon SELPHY CP1500 Auto-heal
After=multi-user.target cups.service
Requires=cups.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/watch_print_disable.sh
# Exécuter en root pour accéder à CUPS
User=root
# Écrire sortie dans le fichier de logs
StandardOutput=journal
StandardError=journal
StandardInput=null

[Install]
WantedBy=multi-user.target
UNIT

# create a timer unit for periodic execution
TIMER_FILE=/etc/systemd/system/${SERVICE_NAME}.timer

echo "Installation du timer -> ${TIMER_FILE}"
cat > "${TIMER_FILE}" <<'TIMER'
[Unit]
Description=Timer for ${SERVICE_NAME}.service (every 30s)

[Timer]
OnUnitActiveSec=30
AccuracySec=1s
Unit=${SERVICE_NAME}.service

[Install]
WantedBy=timers.target
TIMER

echo "Rechargement de systemd..."
systemctl daemon-reload

echo "Activation du service & du timer..."
systemctl enable ${SERVICE_NAME}.service
systemctl enable ${SERVICE_NAME}.timer

echo "Démarrage du timer (le service sera lancé automatiquement toutes les 30s)..."
systemctl start ${SERVICE_NAME}.timer

echo "✓ Installation terminée!"
echo ""
echo "Vérifier le statut :"
echo "  systemctl status ${SERVICE_NAME}.service"
echo "  systemctl status ${SERVICE_NAME}.timer"
echo ""
echo "Voir les logs :"
echo "  journalctl -u ${SERVICE_NAME}.service -f"
