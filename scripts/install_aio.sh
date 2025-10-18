#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME=ups_monitor
DEST_SCRIPT=/usr/local/bin/ups_monitor.py
PROMPT_SCRIPT=/usr/local/bin/ups_touch_prompt.py
UNIT_FILE=/etc/systemd/system/${SERVICE_NAME}.service
LOG_DIR=/var/log/ups_monitor

# retry configuration for GPIO line reservation (modifiable)
REQUEST_RETRY_DELAY=2      # secondes entre tentatives
REQUEST_RETRY_TIMEOUT=300  # timeout total en secondes (0 = infinie)

# paquets utiles pour les popups / gestion fenêtre (Tkinter pour l'interface tactile)
GUI_PACKAGES="python3-tk"

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

echo "Installation du prompt tactile -> ${PROMPT_SCRIPT}"
cat > "${PROMPT_SCRIPT}" <<'PY'
#!/usr/bin/env python3
"""
Prompt tactile Tkinter.
Sortie: exit 0 -> ÉTEINDRE, exit 1 -> RESTER ALLUMÉ
Doit être exécuté dans la session graphique (DISPLAY/XAUTHORITY fournis via l'environnement).
"""
import sys
import tkinter as tk

def main():
    root = tk.Tk()
    root.attributes('-topmost', True)
    root.title("Perte de l'alimentation !")
    root.overrideredirect(True)

    # centered window, not fullscreen (adapt to screen)
    w = root.winfo_screenwidth()
    h = root.winfo_screenheight()
    win_w = min(900, w - 80)
    win_h = min(700, h - 80)
    x = (w - win_w) // 2
    y = (h - win_h) // 2
    root.geometry(f"{win_w}x{win_h}+{x}+{y}")

    bg = tk.Frame(root, bg='#111111')
    bg.pack(fill='both', expand=True)

    # Title two lines centered
    title = tk.Label(bg, text="Perte de l'alimentation !\nVoulez-vous :", 
                     fg='white', bg='#111111', justify='center',
                     font=('Sans', 36, 'bold'))
    title.pack(pady=(30,20))

    # Buttons stacked vertically, large and colored, not side-by-side
    btn_font = ('Sans', 30, 'bold')
    # Éteindre (red)
    def do_shutdown():
        root.quit()
        root.destroy()
        sys.exit(0)
    btn_shutdown = tk.Button(bg, text="ÉTEINDRE", command=do_shutdown,
                             fg='white', bg='#c62828', activebackground='#b71c1c',
                             font=btn_font, width=20, height=2, bd=0)
    btn_shutdown.pack(pady=(20,16))

    # Rester allumé (green)
    def do_stay_on():
        root.quit()
        root.destroy()
        sys.exit(1)
    btn_stay = tk.Button(bg, text="RESTER ALLUMÉ", command=do_stay_on,
                         fg='white', bg='#2e7d32', activebackground='#1b5e20',
                         font=btn_font, width=20, height=2, bd=0)
    btn_stay.pack(pady=(0,30))

    # Prevent accidental close
    root.protocol("WM_DELETE_WINDOW", lambda: None)
    root.focus_force()
    root.mainloop()
    # fallback -> consider as stay on
    sys.exit(1)

if __name__ == '__main__':
    main()
PY
chmod 0755 "${PROMPT_SCRIPT}"

echo "Installation du script monitor -> ${DEST_SCRIPT}"
cat > "${DEST_SCRIPT}" <<'PY'
#!/usr/bin/env python3
# ups_monitor.py - surveille GPIO et affiche prompt tactile via ups_touch_prompt.py

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
DEBOUNCE_SEC = 10
CHECK_INTERVAL = 0.2
PROMPT_TIMEOUT = 0    # 0 => GUI reste ouverte jusqu'à réponse (le monitor tue le dialog si secteur revient)
PRE_PROMPT_SEC = 5

ALLOW_SHUTDOWN = False
if os.environ.get('UPM_ALLOW_SHUTDOWN', '').lower() in ('1', 'true', 'yes'):
    ALLOW_SHUTDOWN = True

if os.geteuid() == 0:
    LOG_DIR = '/var/log/ups_monitor'
else:
    LOG_DIR = os.path.expanduser('~/.local/share/ups_monitor')
os.makedirs(LOG_DIR, exist_ok=True)
LOG_FILE = os.path.join(LOG_DIR, 'ups_monitor.log')

logger = logging.getLogger()
logger.setLevel(logging.INFO)
fh = logging.handlers.RotatingFileHandler(LOG_FILE, maxBytes=5*1024*1024, backupCount=5, encoding='utf-8')
fmt = logging.Formatter('%(asctime)s [%(levelname)s] %(message)s')
fh.setFormatter(fmt)
logger.addHandler(fh)
sh = logging.StreamHandler(sys.stderr)
sh.setFormatter(fmt)
logger.addHandler(sh)

def shutdown_now():
    logging.info("shutdown_now() ALLOW_SHUTDOWN=%s", ALLOW_SHUTDOWN)
    if not ALLOW_SHUTDOWN:
        logging.info("Mode test: pas d'extinction exécutée")
        print("Mode test: pas d'extinction exécutée", file=sys.stderr)
        return
    try:
        subprocess.run(['/bin/systemctl', '--no-block', 'poweroff'], check=False)
    except Exception:
        logging.exception("Erreur lors du shutdown")

def get_active_gui_session():
    try:
        if shutil.which('loginctl'):
            out = subprocess.check_output(['loginctl','list-sessions','--no-legend'], text=True)
            for line in out.splitlines():
                parts = line.split()
                if not parts:
                    continue
                sess = parts[0]
                props = subprocess.check_output(['loginctl','show-session',sess,'--property=Active','--property=Display','--property=Type','--property=Name','--property=UID'], text=True)
                d = {}
                for p in props.splitlines():
                    if '=' in p:
                        k,v = p.split('=',1)
                        d[k]=v
                if d.get('Active','no').lower()=='yes':
                    user=d.get('Name')
                    uid=d.get('UID')
                    try:
                        uid=int(uid)
                    except Exception:
                        uid=None
                    display = d.get('Display') or os.environ.get('DISPLAY',':0')
                    xauth = os.path.join('/home', user, '.Xauthority')
                    if not os.path.exists(xauth):
                        xauth = os.path.join('/run','user',str(uid)) if uid else ''
                    return (user, display, xauth, uid)
    except Exception:
        logging.debug("loginctl failed", exc_info=True)

    # fallback simple
    if os.path.exists('/home/pi'):
        try:
            import pwd
            uid = pwd.getpwnam('pi').pw_uid
        except Exception:
            uid = None
        return ('pi', os.environ.get('DISPLAY',':0'), '/home/pi/.Xauthority', uid)
    return (None, None, None, None)

def _popen_as_user(user, env_vars, cmd):
    env_args = []
    for k,v in (env_vars or {}).items():
        if v is None:
            continue
        env_args.append(f"{k}={v}")
    full = ['sudo','-u',user,'-H','env'] + env_args + cmd
    logging.debug("Lancement commande utilisateur: %s", shlex.join(full))
    try:
        return subprocess.Popen(full)
    except Exception:
        logging.exception("Erreur Popen en tant que user %s", user)
        return None

def prompt_shutdown_confirmation(timeout=PROMPT_TIMEOUT, power_check=None, poll_interval=0.25):
    """
    Lance le prompt tactile (Tkinter) et attend réponse.
    Si power_check() retourne True pendant le prompt, le dialog est tué et la fonction retourne False.
    Retourne True si l'utilisateur choisit ÉTEINDRE, False si RESTER ALLUMÉ ou si killed.
    """
    logging.info("Affichage prompt tactile (timeout=%s)", timeout)
    gui_user, gui_display, gui_xauth, gui_uid = get_active_gui_session()
    logging.debug("Session graphique: %s %s %s %s", gui_user, gui_display, gui_xauth, gui_uid)
    if not gui_user:
        logging.warning("Aucune session graphique trouvée -> fallback console")
        # console fallback
        if sys.stdin.isatty():
            try:
                ans = input("Alimentation perdue. Arrêter la machine ? [Y/n]: ").strip().lower()
                return ans in ('','y','yes','o','oui')
            except Exception:
                return False
        return False

    prompt_path = "/usr/local/bin/ups_touch_prompt.py"
    cmd = ['/usr/bin/python3', prompt_path]
    env = {'DISPLAY': gui_display, 'XAUTHORITY': gui_xauth, 'XDG_RUNTIME_DIR': f'/run/user/{gui_uid}' if gui_uid else None}
    proc = _popen_as_user(gui_user, env, cmd)
    if not proc:
        logging.warning("Impossible de lancer le prompt tactile pour %s", gui_user)
        return False

    try:
        start = time.time()
        while True:
            # if power returns -> kill prompt and cancel shutdown
            if power_check and power_check():
                logging.info("Secteur revenu pendant prompt -> kill dialog et annuler")
                try:
                    proc.kill()
                except Exception:
                    pass
                return False
            ret = proc.poll()
            if ret is not None:
                logging.debug("Prompt terminé rc=%s", ret)
                # ups_touch_prompt: 0 = shutdown, 1 = stay on
                return True if ret == 0 else False
            time.sleep(poll_interval)
    finally:
        try:
            if proc.poll() is None:
                proc.kill()
        except Exception:
            pass

def main():
    logging.info("Démarrage ups_monitor (LOG=%s)", LOG_FILE)
    try:
        chip = gpiod.Chip(CHIP_NAME)
    except Exception:
        logging.exception("Impossible d'ouvrir chip GPIO")
        print("Impossible d'ouvrir chip GPIO", file=sys.stderr)
        sys.exit(1)

    try:
        line = chip.get_line(PLD_PIN)
    except Exception:
        logging.exception("Impossible de récupérer la ligne GPIO")
        print("Impossible de récupérer la ligne GPIO", file=sys.stderr)
        try:
            chip.close()
        except Exception:
            pass
        sys.exit(1)

    # retry params injected by installer
    request_retry_delay = __REQUEST_RETRY_DELAY__
    request_retry_timeout = __REQUEST_RETRY_TIMEOUT__

    snoozed_until_restore = False

    start_time = time.time()
    while True:
        try:
            line.request(consumer="PLD", type=gpiod.LINE_REQ_DIR_IN)
            logging.info("Ligne GPIO réservée")
            break
        except OSError as e:
            elapsed = time.time() - start_time
            if request_retry_timeout and elapsed >= request_retry_timeout:
                logging.error("Timeout réservation ligne GPIO")
                try:
                    chip.close()
                except Exception:
                    pass
                sys.exit(1)
            logging.warning("Réessayer réservation ligne GPIO dans %.1fs", request_retry_delay)
            time.sleep(request_retry_delay)
            continue

    def cleanup(signum=None, frame=None):
        logging.info("Cleanup")
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
            except Exception:
                logging.exception("Erreur lecture GPIO")
                break

            if val == 1:
                # secteur OK -> clear snooze if any
                if snoozed_until_restore:
                    logging.info("Secteur revenu -> reprise normale (snooze clear).")
                    snoozed_until_restore = False
                time.sleep(CHECK_INTERVAL)
                continue

            # detected loss -> debounce
            logging.info("Perte secteur détectée -> debounce %ss", DEBOUNCE_SEC)
            time.sleep(DEBOUNCE_SEC)
            try:
                if line.get_value() != 1:
                    if snoozed_until_restore:
                        logging.info("Prompts en pause (utilisateur a choisi de rester allumé). Attente retour secteur.")
                        while True:
                            try:
                                if line.get_value() == 1:
                                    logging.info("Secteur revenu -> reprise (clear snooze)")
                                    snoozed_until_restore = False
                                    break
                            except Exception:
                                logging.exception("Erreur lecture GPIO pendant snooze")
                                cleanup()
                            time.sleep(CHECK_INTERVAL)
                        continue

                    # pre-prompt confirmation
                    logging.info("Attente pré-prompt %ss", PRE_PROMPT_SEC)
                    t0 = time.time()
                    cancelled = False
                    while time.time() - t0 < PRE_PROMPT_SEC:
                        if line.get_value() == 1:
                            logging.info("Secteur revenu pendant pré-prompt -> annulation")
                            cancelled = True
                            break
                        time.sleep(0.2)
                    if cancelled:
                        continue

                    logging.info("Affichage du prompt tactile")
                    ok = prompt_shutdown_confirmation(timeout=0, power_check=lambda: line.get_value() == 1)
                    if ok:
                        shutdown_now()
                        break
                    else:
                        logging.info("Utilisateur a choisi de rester allumé -> mise en snooze jusqu'au retour du secteur")
                        snoozed_until_restore = True
                        while True:
                            try:
                                if line.get_value() == 1:
                                    logging.info("Secteur revenu après snooze -> reprise")
                                    snoozed_until_restore = False
                                    break
                            except Exception:
                                logging.exception("Erreur lecture GPIO pendant snooze")
                                cleanup()
                            time.sleep(CHECK_INTERVAL)
                        continue
                else:
                    logging.info("Faux positif: secteur revenu pendant debounce")
            except Exception:
                logging.exception("Erreur boucle surveillance")
                break
    finally:
        cleanup()

if __name__ == '__main__':
    main()
PY

# remplacer les placeholders par les valeurs shell (évite expansion dans le here-doc)
sed -i "s/__REQUEST_RETRY_DELAY__/${REQUEST_RETRY_DELAY}/g" "${DEST_SCRIPT}" 2>/dev/null || true
sed -i "s/__REQUEST_RETRY_TIMEOUT__/${REQUEST_RETRY_TIMEOUT}/g" "${DEST_SCRIPT}" 2>/dev/null || true

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
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

echo "Création du dossier de logs ${LOG_DIR}"
mkdir -p "${LOG_DIR}"
chown root:root "${LOG_DIR}" || true
chmod 0755 "${LOG_DIR}"

echo "Reload systemd, enable et start du service ${SERVICE_NAME}"
systemctl daemon-reload
systemctl enable --now ${SERVICE_NAME}.service || true

echo "Installation terminée. Status du service :"
systemctl status ${SERVICE_NAME}.service --no-pager || true

echo
echo "Logs (journal):"
echo "  sudo journalctl -u ${SERVICE_NAME}.service -f"
echo
echo "Fichier de log (si exécuté en root): ${LOG_DIR}/ups_monitor.log"
