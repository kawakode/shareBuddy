# Publier une version

Les versions sont produites automatiquement par GitHub Actions
(`.github/workflows/release.yml`).

## Créer une release

```sh
git checkout main && git pull
git tag v1.2.3
git push origin v1.2.3
```

Le tag doit avoir la forme `vX.Y.Z`. Le workflow :

1. lance les tests (`swift test`) ;
2. compile `ShareMan.app` en binaire universel (Apple Silicon + Intel), avec
   la version du tag dans `Info.plist` ;
3. fabrique `ShareMan.dmg` : à l'ouverture, une fenêtre montre l'application
   à côté d'un raccourci vers **Applications**, il suffit de glisser l'une sur
   l'autre ;
4. compile l'outil en ligne de commande dans `shareman-macos.zip` ;
5. publie la release GitHub, marquée « latest », avec les deux fichiers et des
   notes générées à partir des commits et PR depuis le tag précédent.

Liens stables, toujours vers la dernière version :

- page : https://github.com/kawakode/shareBuddy/releases/latest
- DMG direct : https://github.com/kawakode/shareBuddy/releases/latest/download/ShareMan.dmg

Relancer le workflow sur un tag existant remplace simplement les fichiers de
la release.

Une PR qui modifie `scripts/` ou le workflow fabrique aussi le DMG, sans rien
publier : il est téléchargeable dans les artefacts du run.

## Construire le DMG en local

```sh
scripts/build-app.sh
scripts/make-dmg.sh          # -> build/ShareMan.dmg
```

## Signature et notarisation (facultatives)

Sans configuration, l'application a une signature « ad hoc » : elle
fonctionne, mais au premier lancement macOS refuse de l'ouvrir tant que
l'utilisateur ne passe pas par **Réglages Système › Confidentialité et
sécurité › Ouvrir quand même**. Les notes de release l'expliquent alors
automatiquement.

Pour supprimer cet avertissement, il faut un compte Apple Developer (99 $/an)
et ajouter ces secrets dans **Settings › Secrets and variables › Actions** du
dépôt :

| Secret | Contenu |
| --- | --- |
| `MACOS_CERTIFICATE` | Certificat **Developer ID Application** exporté en `.p12` depuis Trousseaux d'accès, encodé en base64 (`base64 -i cert.p12 \| pbcopy`) |
| `MACOS_CERTIFICATE_PWD` | Mot de passe choisi à l'export du `.p12` |
| `APPLE_ID` | Adresse du compte Apple Developer |
| `APPLE_TEAM_ID` | Identifiant d'équipe (10 caractères, visible sur developer.apple.com › Membership) |
| `APPLE_APP_PASSWORD` | Mot de passe d'application créé sur appleid.apple.com |

Avec seulement les deux premiers, l'application est signée Developer ID mais
pas notarisée. Avec les cinq, le DMG et l'outil en ligne de commande sont
signés, notarisés et le DMG est « agrafé » (stapled) : plus aucun
avertissement à l'ouverture.
