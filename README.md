# PhotoBooth
Conception de pièces et assemblage pour un Photobooth.  
Rassemblement d'idées et de schémas pour la conception.

## Contenu

- Raspberry Pi 5 - 8 Go de RAM
- Carte NVMe - https://wiki.geekworm.com/X1001
- NVMe WD Blue - 1 To
- Onduleur X1200 : https://wiki.geekworm.com/X1200
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

- [x] Ajout d’un UPS pour simplifier la gestion de l’allumage et de l’extinction du photobooth
  - [x] Choix du modèle, voir chez Geekworm X1200 : https://wiki.geekworm.com/X1200
  - [x] ajout d'un script service pour l'extinction en l'absence de tension (10s)
    - installation via script en ligne => "sudo bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Miauto/PhotoBooth/refs/heads/main/scripts/install_aio.sh"
  - [x] allumage a la mise sous tension
  - [x] Forcé l'usb max
- [x] Revoir la gestion d'impression
  - probleme actuel : quand l'imprimante n'a plus de papier ou plus d'encre, alors l'imprimante se desactive sous linux et on est obliger d'aller dans la gestion de l'imprimante pour la reactivé.
  - sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Miauto/PhotoBooth/refs/heads/main/scripts/install_watch_print_disable.sh)"
- [ ] Ajout d’un port USB sur une façade
  - [x] Fiche USB installée
- [ ] Ajout d’une prise d’alimentation type Powercon
  - [x] Fiche en façade
  - [ ] Câble d’alimentation
- [ ] Ajout d’un support pour la caméra
  - [ ] Support imprimé
- [ ] Ajout d’une serrure
- [x] Ajout d’un NVMe
  - [x] Matériel installé
  - [ ] Gérer le multiboot pour avoir un autre OS en parallèle, voir : https://raspberrytips.fr/dual-boot-raspberry-pi/
  - [ ] Installation d’un OS de retro-gaming
- [ ] Mettre à jour photobooth-app vers 8.7
  - [ ] attention aux breakchange
- [ ] Revoir la conception du bouton bluetooth sur batterie, pourquoi pas une pedale, sinon gros bouton
  - [ ] idée autre : https://amzn.eu/d/6wawQ6z / bouton champignon (j'ai)
  - [ ] gestion et accès recharge batterie
  - [ ] solide
  - [ ] bouton On/Off

## Retro-gaming

- [x] choix et ajout d’un OS retro-gaming
  - [ ] Recalbox : https://www.recalbox.com/
  - [ ] Lakka : https://www.lakka.tv/
  - [x] Batocera : https://batocera.org
        Avantage : prise en charge du d'ongle XBox
- [ ] Ajout des manettes
- [ ] Ajout d'un port HDMI pour brancher sur un écran déporter ou videoproj
