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
PRE_PROMPT_SEC = 5   # temporisation avant d'afficher le prompt (évite popups instantanés)

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
    Retourne (user, display, xauth, uid) de la session graphique active,
    ou (None, None, None, None) si introuvable.
    Heuristiques : loginctl -> fallback detection pour Raspberry Pi OS via X0 + processus utilisateurs.
    """
    # 1) try loginctl (systemd)
    try:
        if shutil.which('loginctl'):
            out = subprocess.check_output(['loginctl', 'list-sessions', '--no-legend'], text=True)
            for line in out.splitlines():
                parts = line.split()
                if not parts:
                    continue
                sess = parts[0]
                props = subprocess.check_output(['loginctl', 'show-session', sess, '--property=Active', '--property=Display', '--property=Type', '--property=Name', '--property=UID'], text=True)
                propd = {}
                for p in props.splitlines():
                    if '=' in p:
                        k, v = p.split('=', 1)
                        propd[k] = v
                active = propd.get('Active', 'no').lower()
                sess_type = propd.get('Type', '').lower()
                display = propd.get('Display', '').strip()
                if active == 'yes' and (sess_type in ('x11', 'wayland') or display):
                    user = propd.get('Name')
                    uid = propd.get('UID')
                    try:
                        uid = int(uid)
                    except Exception:
                        uid = None
                    display = display or os.environ.get('DISPLAY', ':0')
                    xauth = os.path.join('/home', user, '.Xauthority')
                    if not os.path.exists(xauth):
                        # fallback to run-time dir for Wayland or missing .Xauthority
                        if uid:
                            xauth = os.path.join('/run', 'user', str(uid), '')
                        else:
                            xauth = ''
                    return (user, display, xauth, uid)
    except Exception:
        logging.debug("loginctl detection failed", exc_info=True)

    # 2) fallback specific for Raspberry Pi OS / X11 : if X0 exists try to find owning user by looking for desktop processes
    try:
        if os.path.exists('/tmp/.X11-unix/X0'):
            # try who first
            try:
                for line in subprocess.check_output(['who'], text=True).splitlines():
                    cols = line.split()
                    if len(cols) >= 2 and cols[1].startswith(':0'):
                        user = cols[0]
                        try:
                            import pwd
                            uid = pwd.getpwnam(user).pw_uid
                        except Exception:
                            uid = None
                        display = ':0'
                        xauth = os.path.join('/home', user, '.Xauthority')
                        return (user, display, xauth, uid)
            except Exception:
                pass

            # otherwise heuristics: scan ps for common desktop/session processes run by non-root users
            try:
                procs = subprocess.check_output(['ps', '-eo', 'uid,user,cmd'], text=True)
                candidates = []
                for pline in procs.splitlines():
                    cols = pline.strip().split(None, 2)
                    if len(cols) < 3:
                        continue
                    uid_s, user, cmd = cols
                    if user in ('root','systemd','message+'):
                        continue
                    cmd_l = cmd.lower()
                    if any(k in cmd_l for k in ('lxsession','lxpanel','openbox','startlxde','lightdm','x-session-manager','xinit','xfce4-session','gnome-session','mate-session','kdeinit')):
                        candidates.append((int(uid_s), user))
                if candidates:
                    # prefer lowest UID recent candidate
                    uid, user = candidates[0]
                    display = ':0'
                    xauth = os.path.join('/home', user, '.Xauthority')
                    return (user, display, xauth, uid)
            except Exception:
                logging.debug("process-based GUI detection failed", exc_info=True)
    except Exception:
        pass

    # 3) last resort: try common user 'pi'
    try:
        if os.path.exists('/home/pi'):
            xauth = '/home/pi/.Xauthority'
            uid = None
            try:
                import pwd
                uid = pwd.getpwnam('pi').pw_uid
            except Exception:
                uid = None
            display = os.environ.get('DISPLAY', ':0')
            return ('pi', display, xauth, uid)
    except Exception:
        pass

    return (None, None, None, None)

def _popen_as_user(user, env_vars, cmd):
    """
    Lance cmd (list) en tant que user via sudo -u -H env ..., retourne subprocess.Popen ou None.
    """
    env_args = []
    for k, v in (env_vars or {}).items():
        if v is None:
            continue
        env_args.append(f"{k}={v}")
    full = ['sudo', '-u', user, '-H', 'env'] + env_args + cmd
    logging.debug("Popen pour l'utilisateur graphique: %s", shlex.join(full))
    try:
        return subprocess.Popen(full)
    except Exception:
        logging.exception("Erreur Popen en tant que user %s", user)
        return None

def _run_as_user(user, env_vars, cmd):
    """
    Lance cmd (list) en tant que user via sudo -u -H env..., retourne CompletedProcess ou None.
    """
    env_args = []
    for k, v in (env_vars or {}).items():
        if v is None:
            continue
        env_args.append(f"{k}={v}")
    full = ['sudo', '-u', user, '-H', 'env'] + env_args + cmd
    logging.debug("Lancement commande pour l'utilisateur graphique: %s", shlex.join(full))
    try:
        return subprocess.run(full, check=False)
    except Exception:
        logging.exception("Erreur exécution commande en tant que user %s", user)
        return None

def prompt_shutdown_confirmation(timeout=30, power_check=None, poll_interval=0.25):
    """
    Retourne True pour confirmer l'arrêt (Oui), False sinon.
    power_check: callable() -> True si secteur OK.
    Cette version lance le dialog en background et vérifie power_check périodiquement :
    si le secteur revient, le dialog est tué et la fonction retourne False.
    """
    logging.info("Affichage du prompt de confirmation (timeout=%ss)", timeout)
    gui_user, gui_display, gui_xauth, gui_uid = get_active_gui_session()
    logging.debug("Session graphique détectée: user=%s display=%s xauth=%s uid=%s", gui_user, gui_display, gui_xauth, gui_uid)

    # helper to interpret return codes
    def _is_yes_rc(rc, tool):
        if tool == 'yad':
            return rc == 0
        if tool == 'zenity':
            return rc == 0
        return False

    # 1) yad (préféré) - design tactile: gros texte, gros boutons, undecorated
    yad = shutil.which('yad')
    if yad and gui_user:
        text = "<span face='Sans' size='xx-large'><b>Alimentation secteur perdue\n\nArrêter la machine ?</b></span>"
        cmd = [
            yad,
            '--title', 'Alimentation perdue',
            '--text', text,
            '--button=Rester allumé:1',
            '--button=Éteindre:0',
            '--on-top', '--center',
            '--timeout', str(timeout),
            '--borders=20',
            '--fontname=Sans Bold 36',
            '--undecorated'
        ]
        env = {'DISPLAY': gui_display, 'XAUTHORITY': gui_xauth, 'XDG_RUNTIME_DIR': f'/run/user/{gui_uid}' if gui_uid else None}
        proc = _popen_as_user(gui_user, env, cmd)
        if proc:
            start = time.time()
            try:
                while True:
                    # si secteur revenu, kill dialog et annuler
                    if power_check and power_check():
                        logging.info("Secteur revenu pendant prompt -> kill dialog et annuler l'arrêt")
                        try:
                            proc.kill()
                        except Exception:
                            pass
                        return False
                    ret = proc.poll()
                    if ret is not None:
                        logging.debug("yad finished rc=%s", ret)
                        if ret == 0:
                            return True
                        if ret in (252, 5):
                            logging.info("Dialog yad timeout -> considérer comme OUI")
                            return True
                        return False
                    if time.time() - start > (timeout + 5):
                        logging.info("Dialog exceeded timeout -> considérer comme OUI")
                        try:
                            proc.kill()
                        except Exception:
                            pass
                        return True
                    time.sleep(poll_interval)
            finally:
                try:
                    if proc.poll() is None:
                        proc.kill()
                except Exception:
                    pass

    # 2) zenity fallback (run as user via sudo -u)
    zenity = shutil.which('zenity')
    if zenity and gui_user:
        cmd = [
            zenity, '--question',
            '--title', 'Alimentation perdue',
            '--text', 'Alimentation secteur perdue. Arrêter la machine ?',
            '--ok-label', 'Éteindre', '--cancel-label', 'Rester allumé',
            '--timeout', str(timeout)
        ]
        env = {'DISPLAY': gui_display, 'XAUTHORITY': gui_xauth, 'XDG_RUNTIME_DIR': f'/run/user/{gui_uid}' if gui_uid else None}
        proc = _popen_as_user(gui_user, env, cmd)
        if proc:
            start = time.time()
            try:
                while True:
                    if power_check and power_check():
                        logging.info("Secteur revenu pendant prompt -> kill dialog et annuler l'arrêt")
                        try:
                            proc.kill()
                        except Exception:
                            pass
                        return False
                    ret = proc.poll()
                    if ret is not None:
                        logging.debug("zenity finished rc=%s", ret)
                        if ret == 0:
                            return True
                        if ret in (5,):
                            logging.info("Dialog zenity timeout -> considérer comme OUI")
                            return True
                        return False
                    if time.time() - start > (timeout + 5):
                        logging.info("Dialog exceeded timeout -> considérer comme OUI")
                        try:
                            proc.kill()
                        except Exception:
                            pass
                        return True
                    time.sleep(poll_interval)
            finally:
                try:
                    if proc.poll() is None:
                        proc.kill()
                except Exception:
                    pass

    # 3) console fallback: if interactive, use alarm (timeout => YES). If no TTY, do NOT auto-YES.
    if sys.stdin.isatty():
        logging.info("Aucun affichage graphique -> prompt console (interactive)")
        try:
            def _alarm_handler(signum, frame):
                raise TimeoutError
            prev = signal.getsignal(signal.SIGALRM)
            signal.signal(signal.SIGALRM, _alarm_handler)
            signal.alarm(timeout)
            try:
                ans = input(f"Alimentation perdue. Arrêter la machine ? [Y/n] (auto-YES dans {timeout}s): ").strip().lower()
                signal.alarm(0)
                signal.signal(signal.SIGALRM, prev)
                return ans in ('', 'y', 'yes', 'o', 'oui')
            except TimeoutError:
                logging.info("Prompt console timeout -> considérer comme OUI")
                signal.signal(signal.SIGALRM, prev)
                return True
            except EOFError:
                logging.info("Pas de stdin -> annulation")
                signal.signal(signal.SIGALRM, prev)
                return False
        finally:
            try:
                signal.alarm(0)
            except Exception:
                pass

    logging.warning("Pas de GUI et pas de TTY -> annulation (pas d'auto-YES)")
    return False

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
    request_retry_delay = __REQUEST_RETRY_DELAY__    # secondes entre tentatives
    request_retry_timeout = __REQUEST_RETRY_TIMEOUT__  # secondes au total avant abandon (0 = infini)

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
                    logging.info("Perte secteur confirmée, attente pré-prompt %ss", PRE_PROMPT_SEC)
                    # courte temporisation avant popup pour confirmer état (annule si secteur revient)
                    t0 = time.time()
                    cancelled = False
                    while time.time() - t0 < PRE_PROMPT_SEC:
                        if line.get_value() == 1:
                            logging.info("Secteur revenu pendant pré-prompt -> annulation affichage")
                            cancelled = True
                            break
                        time.sleep(0.2)
                    if cancelled:
                        continue  # retour à la boucle de surveillance

                    logging.info("Affichage du prompt de confirmation.")
                    print("Perte secteur confirmée, affichage du prompt de confirmation.", file=sys.stderr)
                    # la fonction va tuer le dialog si secteur revient
                    ok = prompt_shutdown_confirmation(timeout=PROMPT_TIMEOUT, power_check=lambda: line.get_value() == 1)
                    if ok:
                        shutdown_now()
                        # si shutdown lancé, on peut quitter
                        break
                    else:
                        logging.info("Utilisateur a choisi de rester allumé ou prompt annulé. Continuer la surveillance.")
                        # ne pas break : continuer la surveillance et reposer la question lors d'une nouvelle coupure
                        continue
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

# remplacer les placeholders par les valeurs shell (évite expansion dans le here-doc)
sed -i "s/__REQUEST_RETRY_DELAY__/${REQUEST_RETRY_DELAY}/g" "${DEST_SCRIPT}"
sed -i "s/__REQUEST_RETRY_TIMEOUT__/${REQUEST_RETRY_TIMEOUT}/g" "${DEST_SCRIPT}"

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
# Environment=UPM_ALLOW_SHUTDOWN=1   # disabled by default - enable explicitly if you want auto shutdown
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