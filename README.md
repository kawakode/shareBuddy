<p align="center">
  <img src="docs/images/shareman-readme.png" alt="ShareMan" width="320">
</p>

<p align="center">
  <strong>Trouvez les partages NFS et SMB de votre réseau, et montez-les sur votre Mac en un clic.</strong><br>
  Sans <code>sudo</code>, sans configuration.
</p>

<p align="center">
  <a href="https://kawakode.github.io/shareBuddy/">Site web</a> ·
  <a href="#installation">Installation</a> ·
  <a href="#ligne-de-commande">Ligne de commande</a> ·
  <a href="#problèmes-courants">Problèmes courants</a>
</p>

---

## En bref

- **Trouve** les serveurs de votre réseau local, via Bonjour et un scan rapide du sous-réseau. NFS d'abord, SMB ensuite.
- **Liste** les exports NFS et les partages SMB de chaque serveur.
- **Monte** le partage choisi dans `/Volumes`, comme « Se connecter au serveur » du Finder. Le trousseau est utilisé automatiquement.
- **Scan approfondi** pour les serveurs NFS discrets, qui ne s'annoncent pas et répondent mal au scan normal.
- Une **application** simple et un **outil en ligne de commande** (`shareman`), qui partagent le même moteur.

## Installation

Il faut macOS 13 ou plus récent, et Xcode ou les Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/kawakode/shareBuddy.git
cd shareBuddy

scripts/build-app.sh --install                 # ShareMan.app dans /Applications
swift build -c release                         # l'outil en ligne de commande
cp .build/release/shareman /usr/local/bin/     # facultatif
```

Au premier scan, macOS demande l'accès au **réseau local** : acceptez, sinon aucun serveur ne sera trouvé.

## Application

À gauche, les serveurs trouvés. À droite, les partages du serveur choisi, avec un bouton **Monter** (ou **Ouvrir** et **Démonter** s'il est déjà monté).

La barre d'outils permet de choisir NFS, SMB ou les deux, d'activer le scan approfondi et d'indiquer un sous-réseau précis (ex. `10.0.0.0/24`). Un serveur introuvable peut être ajouté à la main par son adresse IP.

## Ligne de commande

```sh
shareman                                   # cherche les serveurs et liste leurs partages
shareman scan --nfs --deep                 # scan NFS approfondi
shareman scan --subnet 10.0.0.0/24         # un autre sous-réseau
shareman scan -v                           # avec un diagnostic des connexions
shareman scan --json                       # pour les scripts

shareman shares nas.local                  # partages d'un serveur précis
shareman shares nas.local --smb --user bob

shareman mount nas.local:/volume1/media    # monte dans /Volumes
shareman mount smb://nas.local/Public --guest
shareman mount //bob@nas.local/Photos --ask-password
shareman mount nas.local:/volume1/media --at ~/NAS/media --read-only

shareman mounts                            # partages montés
shareman unmount /Volumes/media
```

## Problèmes courants

**Aucun serveur trouvé.** Autorisez ShareMan (ou le Terminal, pour la ligne de commande) dans *Réglages Système › Confidentialité et sécurité › Réseau local*. `shareman scan -v` indique si c'est le Mac qui bloque les connexions. Si le serveur ne s'annonce pas, essayez le scan approfondi.

**NFS : « accès refusé » avec un serveur Linux.** macOS se connecte depuis un port non privilégié. Ajoutez l'option `insecure` à l'export, par exemple `/srv/nfs 192.168.1.0/24(rw,insecure)` dans `/etc/exports`, puis `exportfs -ra`. Sur un Synology : *Dossier partagé › Autorisations NFS › Autoriser les connexions depuis des ports non privilégiés*.

**SMB : impossible de lister les partages.** Le serveur refuse l'accès invité. Indiquez un utilisateur : `shareman shares <hôte> --smb --user <nom>`.

<details>
<summary><strong>Comment ça marche</strong></summary>

**Découverte**, en parallèle :

- **Bonjour** : annonces `_nfs._tcp` et `_smb._tcp` (Synology, QNAP, TrueNAS, Mac…).
- **Scan du sous-réseau** : connexion TCP aux ports 2049 (NFS) et 445 (SMB) de chaque adresse, sur chaque interface active. Au-delà d'un /22, seul le /22 du Mac est scanné. Compte 1 à 3 secondes.

**Scan NFS approfondi** (`--deep`) : jusqu'à un /20, délai de connexion de 1,5 s, et interrogation de rpcbind (port 111, requête `GETPORT` en UDP et TCP). Un serveur qui déclare NFS dans rpcbind est retenu même si le port 2049 ne répond pas.

**Liste des partages** avec les outils de macOS : `showmount -e` pour NFS, `smbutil view` pour SMB (les partages cachés comme `IPC$` sont masqués).

**Montage** avec le framework NetFS d'Apple, le même mécanisme que le Finder.

</details>

## Structure du projet

| Dossier | Contenu |
| --- | --- |
| `Sources/ShareManCore` | Le moteur : découverte, listes de partages, montage |
| `Sources/ShareManApp` | L'application SwiftUI |
| `Sources/shareman` | L'outil en ligne de commande |
| `Tests/ShareManCoreTests` | Les tests unitaires (`swift test`) |
| `scripts/build-app.sh` | Fabrique `ShareMan.app` |
| `docs/` | Le site web (GitHub Pages) |
| `assets/branding/` | Icône et logos originaux |
