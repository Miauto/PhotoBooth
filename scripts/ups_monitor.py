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
                    shutdown_now()
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
