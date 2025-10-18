#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME=ups_monitor
DEST_SCRIPT=/usr/local/bin/ups_monitor.py
UNIT_FILE=/etc/systemd/system/${SERVICE_NAME}.service
LOG_DIR=/var/log/ups_monitor

# retry configuration for GPIO line reservation (modifiable)
REQUEST_RETRY_DELAY=2      # secondes entre tentatives
REQUEST_RETRY_TIMEOUT=300  # timeout total en secondes (0 = infinie)

# paquets utiles pour les popups / gestion fenêtre
GUI_PACKAGES="yad zenity wmctrl xdotool"

if [[ $EUID -ne 0 ]]; then
  echo "Ce script doit être exécuté en root. Réessayez avec sudo:"
  echo "  sudo bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Miauto/PhotoBooth/refs/heads/main/scripts/install_aio.sh)\""
  exit 1
fi

echo "Tentative d'installation des paquets GUI utiles: ${GUI_PACKAGES}"
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y --no-install-recommends ${GUI_PACKAGES}
else
  echo "apt-get non disponible — merci d'installer manuellement: ${GUI_PACKAGES}"
fi

echo "Installation du script -> ${DEST_SCRIPT}"
cat > "${DEST_SCRIPT}" <<'PY'
#!/usr/bin/env python3
# Ce script Python est uniquement adapté pour les modules UPS Shield X1200, X1201 et X1202

import gpiod
import time
import subprocess
import sys
import signal
import logging
import logging.handlers
import os
import shutil
import shlex

# Configuration
PLD_PIN = 6
CHIP_NAME = 'gpiochip4'
DEBOUNCE_SEC = 10    # attendre 10s pour confirmer la coupure
CHECK_INTERVAL = 0.2 # pause en fonctionnement normal
PROMPT_TIMEOUT = 30  # secondes pour la popup (timeout = OUI)

# Mode de test / autorisation d'extinction
ALLOW_SHUTDOWN = False           # mettre True pour réellement appeler 'shutdown'
# possibilité d'overrider via variable d'environnement (UPM_ALLOW_SHUTDOWN=1)
if os.environ.get('UPM_ALLOW_SHUTDOWN', '').lower() in ('1', 'true', 'yes'):
    ALLOW_SHUTDOWN = True

# Log file portable : root -> /var/log/ups_monitor/ups_monitor.log, sinon -> ~/.local/share/ups_monitor/ups_monitor.log
if os.geteuid() == 0:
    LOG_DIR = '/var/log/ups_monitor'
else:
    LOG_DIR = os.path.expanduser('~/.local/share/ups_monitor')

os.makedirs(LOG_DIR, exist_ok=True)
LOG_FILE = os.path.join(LOG_DIR, 'ups_monitor.log')

# config logger with rotation
logger = logging.getLogger()
logger.setLevel(logging.INFO)

file_handler = logging.handlers.RotatingFileHandler(
    LOG_FILE, maxBytes=5 * 1024 * 1024, backupCount=5, encoding='utf-8'
)
file_formatter = logging.Formatter('%(asctime)s [%(levelname)s] %(message)s')
file_handler.setFormatter(file_formatter)
logger.addHandler(file_handler)

# also stream to stderr for console visibility
stream_handler = logging.StreamHandler(sys.stderr)
stream_handler.setFormatter(file_formatter)
logger.addHandler(stream_handler)

def shutdown_now():
    logging.info("shutdown_now() appelé, ALLOW_SHUTDOWN=%s", ALLOW_SHUTDOWN)
    if not ALLOW_SHUTDOWN:
        logging.info("Extinction supprimée - mode test. (aucune commande shutdown exécutée)")
        print("Extinction supprimée - mode test.", file=sys.stderr)
        return
    try:
        logging.info("Exécution de la commande shutdown (systemctl --no-block poweroff)")
        subprocess.run(['/bin/systemctl', '--no-block', 'poweroff'], check=False)
    except Exception as e:
        logging.exception("Erreur lancement shutdown: %s", e)
        print("Erreur lancement shutdown:", e, file=sys.stderr)

def get_active_gui_session():
    """
    Tente de détecter la session graphique active et retourne:
      (user, display, xauthority_path) ou (None, None, None)
    Utilise loginctl si disponible, sinon heuristiques (who / :0).
    """
    # Prefer loginctl
    try:
        if shutil.which('loginctl'):
            out = subprocess.check_output(['loginctl', 'list-sessions', '--no-legend'], text=True)
            for line in out.splitlines():
                parts = line.split()
                if not parts:
                    continue
                sess = parts[0]
                props = subprocess.check_output(['loginctl', 'show-session', sess, '--property=Active', '--property=Display', '--property=Type', '--property=Name'], text=True)
                propd = {}
                for p in props.splitlines():
                    if '=' in p:
                        k,v = p.split('=',1)
                        propd[k] = v
                if propd.get('Active','no').lower() == 'yes' and propd.get('Type','').lower() in ('x11','wayland') or propd.get('Display'):
                    user = propd.get('Name')
                    display = propd.get('Display') or os.environ.get('DISPLAY', ':0')
                    xauth = os.path.join('/home', user, '.Xauthority')
                    if not os.path.exists(xauth):
                        xauth = os.path.join('/run', 'user', str(get_uid(user)), 'wayland-0') if False else xauth
                    return (user, display, xauth)
    except Exception:
        pass

    # fallback: who on :0
    try:
        for line in subprocess.check_output(['who'], text=True).splitlines():
            cols = line.split()
            if len(cols) >= 2 and cols[1].startswith(':'):
                user = cols[0]
                display = cols[1]
                xauth = os.path.join('/home', user, '.Xauthority')
                return (user, display, xauth)
    except Exception:
        pass

    return (None, None, None)

def get_uid(username):
    try:
        import pwd
        return pwd.getpwnam(username).pw_uid
    except Exception:
        return None

def _run_as_user(user, env_vars, cmd):
    """
    Exécute cmd (list) en tant que user en utilisant sudo -u (root peut le faire).
    env_vars dict ajoutés via 'env' wrapper pour sudo compatibility.
    """
    env_args = []
    for k,v in env_vars.items():
        env_args.append(f"{k}={v}")
    full = ['sudo', '-u', user, 'env'] + env_args + cmd
    logging.debug("Lancement commande pour l'utilisateur graphique: %s", shlex.join(full))
    try:
        return subprocess.run(full, check=False)
    except Exception:
        logging.exception("Erreur exécution commande en tant que user %s", user)
        return None

def prompt_shutdown_confirmation(timeout=30):
    """
    Retourne True pour confirmer l'arrêt (Oui), False pour annuler.
    Essaie yad (avec --on-top), puis zenity (bring-to-front), en priorité dans
    la session graphique active si détectée. Fallback console avec timeout.
    Le timeout est interprété comme OUI.
    """
    logging.info("Affichage du prompt de confirmation (timeout=%ss)", timeout)
    gui_user, gui_display, gui_xauth = get_active_gui_session()
    logging.debug("Session graphique détectée: user=%s display=%s xauth=%s", gui_user, gui_display, gui_xauth)

    # 1) yad (préféré : supporte on-top / center)
    yad = shutil.which('yad')
    if yad:
        cmd = [
            yad,
            '--width=480', '--height=160',
            '--title', 'Alimentation perdue',
            '--text', 'Alimentation secteur perdue. Arrêter la machine ?',
            '--button=Oui:0', '--button=Non:1',
            '--on-top', '--center',
            '--timeout', str(timeout)
        ]
        if gui_user and gui_display:
            env = {'DISPLAY': gui_display, 'XAUTHORITY': gui_xauth}
            res = _run_as_user(gui_user, env, cmd)
            if res is not None:
                rc = res.returncode
                if rc == 0:
                    return True
                if rc in (252,5):
                    logging.info("Dialog yad timeout -> considérer comme OUI")
                    return True
                return False
        elif os.environ.get('DISPLAY'):
            try:
                proc = subprocess.run(cmd, timeout=timeout+5)
                if proc.returncode == 0:
                    return True
                if proc.returncode in (252,5):
                    logging.info("Dialog yad timeout -> considérer comme OUI")
                    return True
                return False
            except Exception:
                logging.exception("Erreur lancement yad, fallback...")

    # 2) zenity : lancer et tenter bring-to-front
    zenity = shutil.which('zenity')
    if zenity:
        cmd = [
            zenity, '--question',
            '--title', 'Alimentation perdue',
            '--text', 'Alimentation secteur perdue. Arrêter la machine ?',
            '--ok-label', 'Oui', '--cancel-label', 'Non',
            '--timeout', str(timeout)
        ]
        if gui_user and gui_display:
            env = {'DISPLAY': gui_display, 'XAUTHORITY': gui_xauth}
            # run zenity as gui user
            res = _run_as_user(gui_user, env, cmd)
            if res is not None:
                rc = res.returncode
                if rc == 0:
                    return True
                if rc in (5,):
                    logging.info("Dialog zenity timeout -> considérer comme OUI")
                    return True
                return False
        elif os.environ.get('DISPLAY'):
            try:
                p = subprocess.Popen(cmd)
                time.sleep(0.2)
                title = 'Alimentation perdue'
                if shutil.which('wmctrl'):
                    try:
                        subprocess.run(['wmctrl', '-r', title, '-b', 'add,above'], check=False)
                    except Exception:
                        pass
                elif shutil.which('xdotool'):
                    try:
                        out = subprocess.run(['xdotool', 'search', '--name', title], capture_output=True, text=True)
                        for wid in out.stdout.splitlines():
                            subprocess.run(['xdotool', 'windowactivate', '--sync', wid], check=False)
                    except Exception:
                        pass
                try:
                    ret = p.wait(timeout=timeout+5)
                except subprocess.TimeoutExpired:
                    logging.info("Dialog zenity timeout -> considérer comme OUI")
                    try:
                        p.kill()
                    except Exception:
                        pass
                    return True
                if ret == 0:
                    return True
                if ret == 5:
                    logging.info("Dialog zenity timeout code -> considérer comme OUI")
                    return True
                return False
            except Exception:
                logging.exception("Erreur lancement zenity, fallback...")

    # 3) Console fallback (input avec alarm). Timeout => OUI. EOF => OUI.
    try:
        def _alarm_handler(signum, frame):
            raise TimeoutError
        prev_handler = signal.getsignal(signal.SIGALRM)
        signal.signal(signal.SIGALRM, _alarm_handler)
        signal.alarm(timeout)
        try:
            ans = input(f"Alimentation perdue. Arrêter la machine ? [Y/n] (auto-YES dans {timeout}s): ").strip().lower()
            signal.alarm(0)
            signal.signal(signal.SIGALRM, prev_handler)
            if ans in ('', 'y', 'yes', 'o', 'oui'):
                return True
            return False
        except TimeoutError:
            logging.info("Prompt console timeout -> considérer comme OUI")
            signal.signal(signal.SIGALRM, prev_handler)
            return True
        except EOFError:
            logging.info("Pas de stdin disponible -> considérer comme OUI")
            signal.signal(signal.SIGALRM, prev_handler)
            return True
    finally:
        try:
            signal.alarm(0)
        except Exception:
            pass

def main():
    logging.info("Démarrage ups_monitor (LOG_FILE=%s, ALLOW_SHUTDOWN=%s)", LOG_FILE, ALLOW_SHUTDOWN)

    try:
        chip = gpiod.Chip(CHIP_NAME)
    except Exception as e:
        logging.exception("Impossible d'ouvrir le chip GPIO: %s", e)
        print("Impossible d'ouvrir le chip GPIO:", e, file=sys.stderr)
        sys.exit(1)

    try:
        line = chip.get_line(PLD_PIN)
    except Exception as e:
        logging.exception("Impossible de récupérer la ligne GPIO: %s", e)
        print("Impossible de récupérer la ligne GPIO:", e, file=sys.stderr)
        try:
            chip.close()
        except Exception:
            pass
        sys.exit(1)

    # Paramètres de retry injectés par le script d'installation
    request_retry_delay = ${REQUEST_RETRY_DELAY}    # secondes entre tentatives
    request_retry_timeout = ${REQUEST_RETRY_TIMEOUT}  # secondes au total avant abandon (0 = infini)

    start_time = time.time()
    while True:
        try:
            line.request(consumer="PLD", type=gpiod.LINE_REQ_DIR_IN)
            logging.info("Ligne GPIO %s réservée avec succès.", PLD_PIN)
            break
        except OSError as e:
            elapsed = time.time() - start_time
            if request_retry_timeout and elapsed >= request_retry_timeout:
                logging.error("Timeout après %.1fs lors de la réservation de la ligne GPIO: %s", elapsed, e)
                print("Timeout réservation ligne GPIO (voir log).", file=sys.stderr)
                try:
                    chip.close()
                except Exception:
                    pass
                sys.exit(1)
            logging.warning("Impossible de réserver la ligne GPIO (occupée). Reessayer dans %.1fs : %s", request_retry_delay, e)
            time.sleep(request_retry_delay)
            continue
        except Exception as e:
            logging.exception("Erreur lors de la réservation de la ligne GPIO: %s", e)
            print("Erreur lors de la réservation de la ligne GPIO:", e, file=sys.stderr)
            try:
                chip.close()
            except Exception:
                pass
            sys.exit(1)

    def cleanup(signum=None, frame=None):
        logging.info("Cleanup signal reçu (%s). Libération ressources.", signum)
        try:
            line.release()
        except Exception:
            pass
        try:
            chip.close()
        except Exception:
            pass
        sys.exit(0)

    signal.signal(signal.SIGINT, cleanup)
    signal.signal(signal.SIGTERM, cleanup)

    try:
        while True:
            try:
                val = line.get_value()
            except Exception as e:
                logging.exception("Erreur lecture GPIO: %s", e)
                print("Erreur lecture GPIO:", e, file=sys.stderr)
                break

            if val == 1:
                # alimentation secteur OK
                time.sleep(CHECK_INTERVAL)
                continue

            # perte secteur détectée -> debounce
            logging.info("Signal perte secteur détecté, attente debounce %s s", DEBOUNCE_SEC)
            time.sleep(DEBOUNCE_SEC)
            try:
                if line.get_value() != 1:
                    logging.info("Perte secteur confirmée, affichage du prompt de confirmation.")
                    print("Perte secteur confirmée, affichage du prompt de confirmation.", file=sys.stderr)
                    if prompt_shutdown_confirmation(timeout=PROMPT_TIMEOUT):
                        shutdown_now()
                    else:
                        logging.info("Arrêt annulé par l'utilisateur via le prompt.")
                    break
                else:
                    logging.info("Faux positif: alimentation revenue pendant le debounce.")
            except Exception as e:
                logging.exception("Erreur relecture GPIO: %s", e)
                print("Erreur relecture GPIO:", e, file=sys.stderr)
                break

    finally:
        cleanup()

if __name__ == '__main__':
    main()
PY

chmod 0755 "${DEST_SCRIPT}"

echo "Création du fichier unit systemd -> ${UNIT_FILE}"
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
# Pour autoriser l'extinction automatiquement via le service, décommentez et mettez =1 :
Environment=UPM_ALLOW_SHUTDOWN=1
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

echo "Création du dossier de logs ${LOG_DIR}"
mkdir -p "${LOG_DIR}"
chown root:root "${LOG_DIR}"
chmod 0755 "${LOG_DIR}"

echo "Reload systemd, enable et start du service ${SERVICE_NAME}"
systemctl daemon-reload
systemctl enable --now ${SERVICE_NAME}.service

echo "Installation terminée. Status du service :"
systemctl status ${SERVICE_NAME}.service --no-pager

echo
echo "Logs (journal):"
echo "  sudo journalctl -u ${SERVICE_NAME}.service -f"
echo
echo "Fichier de log (si exécuté en root): ${LOG_DIR}/ups_monitor.log"