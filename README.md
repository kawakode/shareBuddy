# ShareMan

ShareMan trouve les partages réseau **NFS** et **SMB** de ton réseau local et les monte sur macOS, sans `sudo`.

NFS est le protocole prioritaire : les serveurs NFS sont listés en premier et leurs exports sont affichés directement.

## Installation

Prérequis : macOS 13 ou plus récent, et Xcode ou les Command Line Tools (`xcode-select --install`).

```sh
swift build -c release
cp .build/release/shareman /usr/local/bin/   # facultatif
```

## Application

```sh
scripts/build-app.sh            # crée build/ShareMan.app
scripts/build-app.sh --install  # et la copie dans /Applications
```

La fenêtre liste les serveurs trouvés à gauche et les exports / partages du serveur choisi à droite, avec un bouton **Monter** (ou **Ouvrir** / **Démonter** s'il est déjà monté). La barre d'outils permet de choisir NFS, SMB ou les deux, d'activer le **scan approfondi**, et d'indiquer un sous-réseau précis (ex. `10.0.0.0/24`). Un serveur introuvable peut aussi être ajouté à la main par son IP.

Au premier scan, macOS demande l'autorisation d'accéder au **réseau local** : accepte-la, sinon aucun serveur ne sera trouvé.

Pour un essai rapide sans créer l'app : `swift run ShareManApp`.

## Ligne de commande

```sh
# Cherche les serveurs NFS et SMB et liste leurs partages (commande par défaut)
shareman
shareman scan --nfs                 # uniquement NFS
shareman scan --subnet 10.0.0.0/24  # un autre sous-réseau
shareman scan --nfs --deep          # scan NFS approfondi (voir plus bas)
shareman scan -v                    # avec un diagnostic des connexions
shareman scan --json                # pour les scripts

# Liste les exports / partages d'un serveur précis
shareman shares nas.local
shareman shares nas.local --smb --user bob   # demande le mot de passe si besoin

# Monte un partage (dans /Volumes par défaut)
shareman mount nfs://nas.local/volume1/media
shareman mount nas.local:/volume1/media                # notation NFS classique
shareman mount smb://nas.local/Public --guest
shareman mount //bob@nas.local/Photos --ask-password
shareman mount nas.local:/volume1/media --at ~/NAS/media --read-only

# Partages montés, démontage
shareman mounts
shareman unmount /Volumes/media
```

## Fonctionnement

**Découverte** (en parallèle) :

1. **Bonjour** : écoute des annonces `_nfs._tcp` et `_smb._tcp` (Synology, QNAP, TrueNAS, Mac avec partage de fichiers…).
2. **Scan du sous-réseau** : tentative de connexion TCP sur le port 2049 (NFS) et 445 (SMB) de chaque adresse du sous-réseau de chaque interface active. Les sous-réseaux plus grands qu'un /22 sont réduits au /22 qui contient l'adresse du Mac. Un scan normal prend 1 à 3 secondes.

**Scan NFS approfondi** (`--deep`, ou le bouton « Scan approfondi » de l'app), pour les serveurs NFS sans Bonjour qui ne répondent pas au scan normal :

- sous-réseau entier jusqu'à un /20 (4094 adresses) au lieu d'un /22 ;
- délai de connexion porté à 1,5 s ;
- sondage du port 111 (rpcbind) en plus du 2049, puis requête RPC `GETPORT` au portmapper, en UDP vers chaque adresse et en TCP vers les hôtes dont le port 111 est ouvert. Un serveur qui déclare NFS dans rpcbind est retenu même si le port 2049 n'a pas répondu.

**Liste des partages** avec les outils fournis par macOS :

- NFS : `showmount -e <hôte>` (exports et clients autorisés).
- SMB : `smbutil view //<hôte>` (en invité par défaut, ou avec `--user`). Les partages cachés (`IPC$`, `C$`…) sont masqués.

**Montage** via le framework **NetFS** d'Apple, le même mécanisme que « Aller > Se connecter au serveur » dans le Finder. Les mots de passe enregistrés dans le trousseau sont utilisés automatiquement.

## Problèmes courants

- **NFS « accès refusé » avec un serveur Linux** : macOS se connecte depuis un port non privilégié (> 1024). Ajoute l'option `insecure` à l'export dans `/etc/exports`, par exemple `/srv/nfs 192.168.1.0/24(rw,insecure)`, puis `exportfs -ra`. Sur un Synology : *Panneau de configuration > Dossier partagé > Autorisations NFS > Autoriser les connexions depuis des ports non privilégiés*.
- **Aucun serveur trouvé** : sur macOS 15 et plus, autorise ShareMan, ou le Terminal pour la ligne de commande, dans *Réglages Système > Confidentialité et sécurité > Réseau local*. Quand toutes les connexions sont bloquées par le Mac lui-même, ShareMan l'indique. `shareman scan -v` affiche le détail.
- **SMB : impossible de lister les partages** : le serveur refuse l'accès invité. Utilise `shareman shares <hôte> --smb --user <nom>`.

## Structure

- `Sources/ShareManCore` : bibliothèque réutilisable (découverte, listes de partages, montage). Partagée par la CLI et l'app.
- `Sources/shareman` : l'outil en ligne de commande.
- `Sources/ShareManApp` : l'application SwiftUI (et son `Info.plist`).
- `scripts/build-app.sh` : fabrique `ShareMan.app`.
- `Tests/ShareManCoreTests` : tests unitaires (`swift test`).
