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
