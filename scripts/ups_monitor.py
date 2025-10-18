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

# Configuration
PLD_PIN = 6
CHIP_NAME = 'gpiochip4'
DEBOUNCE_SEC = 10    # attendre 10s pour confirmer la coupure
CHECK_INTERVAL = 0.2 # pause en fonctionnement normal

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
        # utilise systemctl pour être plus compatible
        subprocess.run(['/bin/systemctl', '--no-block', 'poweroff'], check=False)
    except Exception as e:
        logging.exception("Erreur lancement shutdown: %s", e)
        print("Erreur lancement shutdown:", e, file=sys.stderr)

def prompt_shutdown_confirmation(timeout=30):
    """
    Retourne True pour confirmer l'arrêt (Oui), False pour annuler.
    Essaie d'abord une UI GTK (zenity), puis yad, puis console avec timeout.
    Le timeout est interprété comme OUI.
    """
    logging.info("Affichage du prompt de confirmation (timeout=%ss)", timeout)

    # 1) zenity (GTK)
    zenity = shutil.which('zenity')
    if zenity and os.environ.get('DISPLAY'):
        try:
            proc = subprocess.run([
                zenity, '--question',
                '--title', 'Alimentation perdue',
                '--text', 'Alimentation secteur perdue. Arrêter la machine ?',
                '--ok-label', 'Oui', '--cancel-label', 'Non',
                '--timeout', str(timeout)
            ], timeout=timeout + 5)
            # zenity: 0=OK, 1=Cancel, 5=timeout
            if proc.returncode == 0:
                return True
            if proc.returncode == 5:
                logging.info("Dialog zenity timeout -> considérer comme OUI")
                return True
            return False
        except Exception:
            logging.exception("Erreur lancement zenity, fallback...")

    # 2) yad (si présent)
    yad = shutil.which('yad')
    if yad and os.environ.get('DISPLAY'):
        try:
            proc = subprocess.run([
                yad, '--width=420', '--height=160',
                '--title', 'Alimentation perdue',
                '--text', 'Alimentation secteur perdue. Arrêter la machine ?',
                '--button=Oui:0', '--button=Non:1',
                '--timeout', str(timeout)
            ], timeout=timeout + 5)
            # yad: 0=Oui, 1=Non, 252=timeout (varie selon version) -> traiter timeout comme Oui
            if proc.returncode == 0:
                return True
            if proc.returncode in (252, 5):
                logging.info("Dialog yad timeout -> considérer comme OUI")
                return True
            return False
        except Exception:
            logging.exception("Erreur lancement yad, fallback...")

    # 3) Console fallback (input avec alarm). Timeout => OUI. EOF (pas de stdin) => OUI.
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
        line.request(consumer="PLD", type=gpiod.LINE_REQ_DIR_IN)
    except Exception as e:
        logging.exception("Impossible de réserver la ligne GPIO: %s", e)
        print("Impossible de réserver la ligne GPIO:", e, file=sys.stderr)
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
                    logging.info("Perte secteur confirmée, arrêt système demandé.")
                    print("Perte secteur confirmée, arrêt système.", file=sys.stderr)
                    if prompt_shutdown_confirmation(timeout=30):
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
