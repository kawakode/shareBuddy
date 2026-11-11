# shareBuddy

shareBuddy trouve les partages réseau **NFS** et **SMB** de ton réseau local et les monte sur macOS, sans `sudo`.

NFS est le protocole prioritaire : les serveurs NFS sont listés en premier et leurs exports sont affichés directement.

## Installation

Prérequis : macOS 13 ou plus récent, et Xcode ou les Command Line Tools (`xcode-select --install`).

```sh
swift build -c release
cp .build/release/sharebuddy /usr/local/bin/   # facultatif
```

## Utilisation

```sh
# Cherche les serveurs NFS et SMB et liste leurs partages (commande par défaut)
sharebuddy
sharebuddy scan --nfs                 # uniquement NFS
sharebuddy scan --subnet 10.0.0.0/24  # un autre sous-réseau
sharebuddy scan --json                # pour les scripts

# Liste les exports / partages d'un serveur précis
sharebuddy shares nas.local
sharebuddy shares nas.local --smb --user bob   # demande le mot de passe si besoin

# Monte un partage (dans /Volumes par défaut)
sharebuddy mount nfs://nas.local/volume1/media
sharebuddy mount nas.local:/volume1/media                # notation NFS classique
sharebuddy mount smb://nas.local/Public --guest
sharebuddy mount //bob@nas.local/Photos --ask-password
sharebuddy mount nas.local:/volume1/media --at ~/NAS/media --read-only

# Partages montés, démontage
sharebuddy mounts
sharebuddy unmount /Volumes/media
```

## Fonctionnement

**Découverte** (en parallèle) :

1. **Bonjour** : écoute des annonces `_nfs._tcp` et `_smb._tcp` (Synology, QNAP, TrueNAS, Mac avec partage de fichiers…).
2. **Scan du sous-réseau** : tentative de connexion TCP sur le port 2049 (NFS) et 445 (SMB) de chaque adresse du sous-réseau de chaque interface active. Les gros sous-réseaux sont réduits au /24 qui contient l'adresse du Mac. Un /24 complet prend environ 2 à 3 secondes.

**Liste des partages** avec les outils fournis par macOS :

- NFS : `showmount -e <hôte>` (exports et clients autorisés).
- SMB : `smbutil view //<hôte>` (en invité par défaut, ou avec `--user`). Les partages cachés (`IPC$`, `C$`…) sont masqués.

**Montage** via le framework **NetFS** d'Apple, le même mécanisme que « Aller > Se connecter au serveur » dans le Finder. Les mots de passe enregistrés dans le trousseau sont utilisés automatiquement.

## Problèmes courants

- **NFS « accès refusé » avec un serveur Linux** : macOS se connecte depuis un port non privilégié (> 1024). Ajoute l'option `insecure` à l'export dans `/etc/exports`, par exemple `/srv/nfs 192.168.1.0/24(rw,insecure)`, puis `exportfs -ra`. Sur un Synology : *Panneau de configuration > Dossier partagé > Autorisations NFS > Autoriser les connexions depuis des ports non privilégiés*.
- **Aucun serveur trouvé** : sur macOS 15 et plus, autorise le Terminal (ou ton app de terminal) dans *Réglages Système > Confidentialité et sécurité > Réseau local*.
- **SMB : impossible de lister les partages** : le serveur refuse l'accès invité. Utilise `sharebuddy shares <hôte> --smb --user <nom>`.

## Structure

- `Sources/ShareBuddyCore` : bibliothèque réutilisable (découverte, listes de partages, montage). Elle servira aussi à la future app de la barre des menus.
- `Sources/sharebuddy` : l'outil en ligne de commande.
- `Tests/ShareBuddyCoreTests` : tests unitaires (`swift test`).
