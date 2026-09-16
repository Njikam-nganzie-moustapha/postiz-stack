# postiz-stack — Postiz allégé sur ton PC, accessible en HTTPS via Tailscale

Publie tes vidéos et images sur tous tes réseaux (TikTok, YouTube, Instagram, Facebook, X, LinkedIn, Threads, Pinterest, Reddit, Bluesky, Mastodon…) depuis **ton propre ordinateur**, avec [Postiz](https://github.com/gitroomhq/postiz-app) (open source, AGPL-3.0), sans serveur à payer.

Ce dépôt ne contient **aucune donnée personnelle** : uniquement la configuration Docker et les scripts. Chaque personne qui l'installe a **sa propre instance**, ses propres comptes, ses propres sauvegardes.

## Pourquoi Tailscale ?

TikTok et Instagram ne reçoivent pas ta vidéo : ils viennent **la chercher** à une adresse publique HTTPS. Un Postiz sur `localhost` ne peut donc pas publier chez eux. [Tailscale Funnel](https://tailscale.com/kb/1223/funnel) (gratuit) donne à ton PC une adresse publique `https://ton-pc.tailXXXX.ts.net` sans domaine à acheter ni carte bancaire. C'est tout ce qu'il fait ici.

## Ce qui a été retiré de la stack officielle, et pourquoi

| Module | Rôle | Ici |
|---|---|---|
| postiz, postgres, redis | l'application et ses données | **gardés** |
| temporal + sa base | moteur de planification (obligatoire depuis Postiz 2.12) | **gardés**, sans Elasticsearch |
| elasticsearch | index de recherche pour des milliers de workflows en parallèle | retiré (~300 MB, 512 MB RAM) |
| temporal-ui | interface de debug du moteur | désactivée (`docker compose --profile debug up` pour l'ouvrir) |
| temporal-admin-tools, spotlight | outils développeur | retirés |

**Poids** : ~1,4 GB à télécharger la première fois, 3,5–4 GB sur disque, ~1,5 GB de RAM quand ça tourne.

## Prérequis

- Windows 10/11 64-bit, Linux ou macOS.
- [Docker Desktop](https://docs.docker.com/desktop/) (Windows : WSL2 et virtualisation activée dans le BIOS).
- [Tailscale](https://tailscale.com/download) installé et connecté (compte gratuit).
- [GitHub CLI](https://cli.github.com) connecté (`gh auth login`) — pour le dépôt privé de sauvegardes.
- Git.

Dans la [console Tailscale](https://login.tailscale.com/admin) :
1. **DNS** → activer *MagicDNS* et *HTTPS Certificates*.
2. **Access Controls** → ajouter dans la policy :
   ```json
   "nodeAttrs": [ { "target": ["autogroup:member"], "attr": ["funnel"] } ]
   ```

## Installation (une seule fois)

```powershell
git clone https://github.com/Njikam-nganzie-moustapha/postiz-stack.git
cd postiz-stack
powershell -ExecutionPolicy Bypass -File scripts\setup.ps1     # Linux/macOS : bash scripts/setup.sh
```

`setup` :
- crée `.env` (adresse Funnel détectée, `JWT_SECRET` généré),
- te demande une **passphrase** de sauvegarde (la seule chose à ne jamais perdre),
- crée un dépôt GitHub **privé** `postiz-backups` sur ton compte,
- télécharge les images (~1,4 GB) — `-SkipPull` / `--skip-pull` pour reporter,
- propose de restaurer si une sauvegarde existe déjà.

Puis :

```powershell
powershell -ExecutionPolicy Bypass -File scripts\start.ps1      # bash scripts/start.sh
```

Le navigateur s'ouvre sur `https://ton-pc.tailXXXX.ts.net`. Crée ton compte, puis mets `DISABLE_REGISTRATION=true` dans `.env` (sinon n'importe qui tombant sur l'URL peut s'inscrire) et redémarre.

## Au quotidien

| Action | Commande |
|---|---|
| Démarrer | `scripts\start.ps1` — reste ouvert, bloque la mise en veille, **Ctrl+C = sauvegarde + arrêt** |
| Démarrer sans garder la fenêtre | `scripts\start.ps1 -Detach` (pas d'anti-veille) |
| Arrêter | `scripts\stop.ps1` (sauvegarde d'abord) · `-NoBackup` |
| Sauvegarder à la demande | `scripts\backup.ps1` · `-WithUploads` inclut les vidéos (peut être lourd) |
| Sauvegarde auto quotidienne (Windows) | `scripts\schedule-backup.ps1` (03:00, si Postiz tourne) · `-Remove` |
| Restaurer sur un PC neuf | `setup.ps1` puis `scripts\restore.ps1` · `-Force` pour écraser |

Équivalents bash : `start.sh --detach`, `stop.sh --no-backup`, `backup.sh --with-uploads`, `restore.sh --force`.

**PC branché, capot ouvert.** `start` empêche la veille automatique mais pas la fermeture du capot.

## Connecter tes réseaux (clés API)

Chaque réseau exige une « app » créée par **toi** sur son portail développeur. Ne partage jamais ces clés : elles donnent accès à tes comptes.

Pour chaque réseau : guide officiel `https://docs.postiz.com/providers/<réseau>`, puis colle les clés dans `.env` et redémarre.
**Redirect URI à déclarer** : `https://<ton-pc>.<tailnet>.ts.net/integrations/social/<réseau>`
**CGU / confidentialité** (demandées par TikTok, Meta) : `https://<ton-pc>.<tailnet>.ts.net/legal/terms.html` et `/legal/privacy.html` (fichiers dans `legal/`, adapte-les).

| Réseau | Portail | À savoir avant validation |
|---|---|---|
| TikTok | developers.tiktok.com | app non auditée : posts **privés** seulement, 5 utilisateurs/24 h. Audit = démo vidéo + CGU/confidentialité en ligne. |
| Instagram / Facebook / Threads | developers.facebook.com | compte Instagram **professionnel** ; avant revue, seuls les rôles ajoutés à l'app (toi en *Tester*) peuvent publier. |
| YouTube | console.cloud.google.com | app en mode *Testing* : tokens expirés au bout de **7 jours** → **publie** l'app (écran « non vérifiée », c'est normal) pour des tokens durables. |
| X | developer.x.com | plan gratuit limité en écriture. |
| LinkedIn, Pinterest, Reddit, Bluesky, Mastodon, Discord, Slack | voir doc Postiz | peu de contraintes. |

**Compter les clics sur tes liens** : Postiz délègue à un raccourcisseur (Dub gratuit, Short.io, Kutt). Décommente la section correspondante dans `.env`. Les vues/likes viennent directement des réseaux, rien à configurer.

## Partager ponctuellement (« un taf vite fait »)

Ton instance est à toi. Pour laisser quelqu'un publier via tes comptes ou les siens : Settings → Team → invite, puis retire-le après. Ne remets jamais `DISABLE_REGISTRATION=false`.

Quelqu'un qui veut son propre outil clone ce dépôt et fait son propre `setup` : instance, comptes, apps développeur et sauvegardes séparés.

## Sauvegardes : ce qui est où

| Contenu | Où | Chiffré |
|---|---|---|
| base Postiz (comptes liés, posts, calendrier, stats), base Temporal, `JWT_SECRET` | ton dépôt GitHub privé `postiz-backups`, dossier `latest/` + 30 derniers dans `history/` | **oui**, AES-256, passphrase |
| vidéos / images (`data/uploads`) | ton PC uniquement (sauf `-WithUploads`) | — |
| `.env` (tes clés d'app), `data/` | ton PC uniquement, jamais dans git | — |
| passphrase | Windows : `%LOCALAPPDATA%\postiz-stack\passphrase.dpapi` (chiffrée par ton session Windows) · Linux/macOS : `~/.config/postiz-stack/passphrase` (0600) | — |

Le chiffrement tourne dans un conteneur `alpine/openssl` : rien à installer sur le PC, même résultat sur Windows et Linux.

## Limites à connaître

- **PC éteint à l'heure du post = pas de publication.** Au démarrage suivant, `start` te liste les posts en retard ; republie ou reprogramme depuis le calendrier. (Ce que Postiz fait lui-même d'un post en retard est à observer au premier cas réel.)
- Funnel a une bande passante limitée par Tailscale : suffisante pour des vidéos de quelques dizaines de MB, pas pour du 4K long.
- **Changer de PC** = nouvelle adresse `ts.net` → mettre à jour `FUNNEL_HOST` dans `.env` **et** la redirect URI chez chaque réseau, puis `restore`. Les vidéos des posts déjà programmés doivent être recopiées dans `data/uploads` (ou `backup -WithUploads` avant).
- Le port local `4007` est fixe : il n'est exposé qu'en `127.0.0.1`, Funnel seul le publie. S'il est occupé, `start` s'arrête avec le nom du programme fautif.

## Dépannage

```powershell
docker compose logs -f postiz          # logs de l'app
docker compose ps                      # état des 5 conteneurs
docker compose --profile debug up -d   # + interface Temporal sur http://127.0.0.1:8080
tailscale funnel status                # ce qui est exposé
```

## Licence

Scripts et configuration de ce dépôt : MIT. Postiz reste sous AGPL-3.0 (non modifié, utilisé tel quel via son image officielle).
