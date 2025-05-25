# PhotoBooth
Conception de pièces et assemblage pour un Photobooth.  
Rassemblement d'idées et de schémas pour la conception.

## Contenu

- Raspberry Pi 5 - 8 Go de RAM
- Carte NVMe - https://wiki.geekworm.com/X1001
- NVMe WD Blue - 1 To
- Boitier P579 => https://photobooth-app.org/
- Écran 7" (Bug du tactile à l’allumage, un bouton permet de couper et rallumer l’écran)
- Caméra Pi V3
- LED RING 16 leds - piloté par ESP8266 sous WLED - connecté en USB
- Imprimante Canon CP1500 (bug : se bloque en fin d’impression)
- Éclairage LED
- Multi-port USB interne
- Bouton de déclenchement Bluetooth
- Embase d’enceinte 35 mm (trou pour pied d’enceinte)
- Multiprise 3 prises
- Boitier en bois (conception et réalisation maison - thx les copain)
- Logiciel Photobooth-app => https://photobooth-app.org/

## Liste d’idées

- [ ] Ajout d’un UPS pour simplifier la gestion de l’allumage et de l’extinction du photobooth
  - [ ] Choix du modèle, voir chez Geekworm X1200 : https://wiki.geekworm.com/X1200
- [ ] Revoir la gestion d'impression
- [ ] Ajout d’un port USB sur une façade
  - [x] Fiche USB installée
- [ ] Ajout d’une prise d’alimentation type Powercon
  - [x] Fiche en façade
  - [ ] Câble d’alimentation
- [ ] Ajout d’un support pour la caméra
  - [x] Support imprimé
- [ ] Ajout d’une serrure
- [ ] Ajout d’un NVMe
  - [x] Matériel installé
  - [ ] Gérer le multiboot pour avoir un autre OS en parallèle, voir : https://blog.sbw.be/scips/2024/raspberry-pi-5-multiboot-on-nvme-ssd/434/
  - [ ] Copier l’OS SD vers NVMe, vérifier les partitions
  - [ ] Installation d’un OS de retro-gaming
- [ ] Mettre à jour photobooth-app vers 7.1.0
- [ ] Revoir la conception du bouton bluetooth sur batterie, pourquoi pas une pedale, sinon gros bouton
  - [ ] https://amzn.eu/d/6wawQ6z
  - [ ] gestion et accès recharge batterie
  - [ ] solide
  - [ ] bouton On/Off

## Retro-gaming

- [ ] Ajout d’un OS retro-gaming
  - [ ] Recalbox : https://www.recalbox.com/
  - [ ] Lakka : https://www.lakka.tv/
- [ ] Ajout des manettes
- [ ] Ajout d'un port HDMI pour brancher sur un écran déporter ou videoproj
