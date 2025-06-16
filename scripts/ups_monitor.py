#!/usr/bin/env python3
# Ce script Python est uniquement adapté pour les modules UPS Shield X1200, X1201 et X1202

# rendre executable
# sudo chmod +x ups_monitor.py
# sudo python3 ups_monitor.py
# 
# ajout dans CRON
# sudo crontab -e
# 'ajout de la ligne
# @reboot python3 /chemin/vers/ups_monitor.py &
#


import gpiod
import time
from subprocess import call

PLD_PIN = 6
chip = gpiod.Chip('gpiochip4')
pld_line = chip.get_line(PLD_PIN)
pld_line.request(consumer="PLD", type=gpiod.LINE_REQ_DIR_IN)

try:
    while True:
        pld_state = pld_line.get_value()
        if pld_state == 1:  # Alimentation secteur OK
            pass
        else:  # Pas d'alimentation secteur
            time.sleep(10)  # Attendre 10 secondes
            pld_state = pld_line.get_value()
            if pld_state != 1:  # Toujours pas d'alimentation secteur
                call("sudo nohup shutdown -h now", shell=True)  # Arrêter le système

finally:
    pld_line.release()
