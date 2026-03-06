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

# paquets utiles pour les notifications desktop
NOTIFY_PACKAGES="libnotify-bin"

if [[ $EUID -ne 0 ]]; then
  echo "Ce script doit être exécuté en root. Réessayez avec sudo:"
  echo "  sudo bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Miauto/PhotoBooth/refs/heads/main/scripts/install_watch_print_disable.sh)\""
  exit 1
fi

echo "Tentative d'installation des paquets pour notifications: ${NOTIFY_PACKAGES}"
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y --no-install-recommends ${NOTIFY_PACKAGES}
else
  echo "apt-get non disponible — merci d'installer manuellement: ${NOTIFY_PACKAGES}"
fi

echo "Installation du script WatchPrintDisable -> ${DEST_SCRIPT}"
cat > "${DEST_SCRIPT}" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

# Fonction pour trouver la session GUI active
get_active_gui_session() {
    if command -v loginctl >/dev/null 2>&1; then
        while read -r line; do
            sess=$(echo "$line" | awk '{print $1}')
            if [[ -z "$sess" ]]; then continue; fi
            props=$(loginctl show-session "$sess" --property=Active --property=Display --property=Type --property=Name --property=UID 2>/dev/null || true)
            active=$(echo "$props" | grep '^Active=' | cut -d'=' -f2)
            if [[ "$active" == "yes" ]]; then
                user=$(echo "$props" | grep '^Name=' | cut -d'=' -f2)
                uid=$(echo "$props" | grep '^UID=' | cut -d'=' -f2)
                if [[ -z "$uid" ]]; then uid=$(id -u "$user" 2>/dev/null || echo ""); fi
                display=$(echo "$props" | grep '^Display=' | cut -d'=' -f2)
                if [[ -z "$display" ]]; then display="${DISPLAY:-:0}"; fi
                xauth="/home/$user/.Xauthority"
                if [[ ! -f "$xauth" ]]; then
                    xauth="/run/user/$uid/.Xauthority" 2>/dev/null || xauth=""
                fi
                echo "$user $display $xauth $uid"
                return 0
            fi
        done < <(loginctl list-sessions --no-legend 2>/dev/null || true)
    fi
    # Fallback
    if [[ -d /home/pi ]]; then
        uid=$(id -u pi 2>/dev/null || echo "")
        echo "pi ${DISPLAY:-:0} /home/pi/.Xauthority $uid"
    fi
}

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
    # Notification à l'utilisateur
    logger -t cp1500 "Tentative d'envoi de notification..."
    if command -v notify-send >/dev/null 2>&1; then
      # Trouver la session utilisateur active
      USER_INFO=$(get_active_gui_session)
      logger -t cp1500 "Session trouvée: '$USER_INFO'"
      if [[ -n "$USER_INFO" ]]; then
        USER_NAME=$(echo "$USER_INFO" | cut -d' ' -f1)
        DISPLAY_VAR=$(echo "$USER_INFO" | cut -d' ' -f2)
        XAUTH_FILE=$(echo "$USER_INFO" | cut -d' ' -f3)
        USER_UID=$(echo "$USER_INFO" | cut -d' ' -f4)
        logger -t cp1500 "Utilisateur: $USER_NAME, Display: $DISPLAY_VAR, UID: $USER_UID"
        if [[ -n "$USER_NAME" && -n "$DISPLAY_VAR" && -n "$USER_UID" ]]; then
          DBUS_ADDR="unix:path=/run/user/$USER_UID/bus"
          logger -t cp1500 "Envoi notification avec DBUS: $DBUS_ADDR"
          su - "$USER_NAME" -c "DISPLAY='$DISPLAY_VAR' XAUTHORITY='$XAUTH_FILE' DBUS_SESSION_BUS_ADDRESS='$DBUS_ADDR' notify-send -t 5000 'Imprimante réactivée' 'L\\'imprimante $PRN a été automatiquement réactivée.'" 2>&1 | logger -t cp1500 || logger -t cp1500 "Erreur notification"
        else
          logger -t cp1500 "Variables manquantes pour notification"
        fi
      else
        logger -t cp1500 "Aucune session utilisateur trouvée"
      fi
    else
      logger -t cp1500 "notify-send non disponible"
    fi
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
# the here-doc is unquoted so ${SERVICE_NAME} is expanded into the unit
cat > "${TIMER_FILE}" <<TIMER
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

echo "Désactivation d'une ancienne unité potentielle et activation du service & du timer..."
# ensure leftover symlinks from previous broken unit are removed
systemctl disable --now ${SERVICE_NAME}.service || true
systemctl disable --now ${SERVICE_NAME}.timer || true
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
