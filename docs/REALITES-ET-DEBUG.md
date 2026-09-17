# Réalités constatées, pièges payés, et guide de débogage

Tout ce qui a été **vérifié** (pas supposé) pendant la construction de ce dépôt, avec la date. Si un comportement te surprend, commence ici. Ajoute chaque nouvelle découverte à la fin de la section concernée, datée.

---

## 1. Faits vérifiés sur Postiz (2026-09-15/16)

| Fait | Source | Conséquence ici |
|---|---|---|
| L'image officielle sert frontend **et** backend sur le port interne **5000** (`/api` routé vers le backend) | compose officiel `gitroomhq/postiz-docker-compose` | un seul port publié : `127.0.0.1:4007:5000` |
| **Temporal est obligatoire** depuis Postiz 2.12 (`TEMPORAL_ADDRESS`) | compose officiel | on le garde, avec sa propre base Postgres |
| **Elasticsearch est optionnel** : `ENABLE_ES=false` sur `temporalio/auto-setup` suffit | compose officiel + doc Temporal | retiré (~300 MB download, 512 MB RAM) |
| `dynamicconfig/development-sql.yaml` est monté par Temporal et **doit exister** (2 clés) | compose officiel | fichier copié tel quel |
| `JWT_SECRET` sert aussi de **clé AES des tokens sociaux** en base | code Postiz (`auth.service`) | inclus dans chaque backup chiffré ; **ne jamais le changer** après avoir lié un compte |
| **TikTok et Instagram vont chercher le média à une URL publique HTTPS** ; `localhost`/`/uploads` privés échouent | [docs.postiz.com/providers/tiktok](https://docs.postiz.com/providers/tiktok) | d'où Tailscale Funnel |
| TikTok refuse une redirect URI en `http://` | même page | Funnel = HTTPS obligatoire |
| TikTok non audité : posts **privés** seulement, **5 utilisateurs / 24 h** ; audit exige CGU + confidentialité en ligne | même page | `legal/terms.html`, `legal/privacy.html` servis sur `/legal/` |
| Instagram : compte **professionnel** requis ; avant revue Meta, seuls les rôles ajoutés à l'app publient | [docs.postiz.com/providers/instagram](https://docs.postiz.com/providers/instagram) | t'ajouter comme *Tester* dans l'app Meta |
| Google OAuth en mode *Testing* : **refresh tokens expirés après 7 jours** | doc Google OAuth | publier l'app (écran « non vérifiée ») |
| Les **clics** sur liens ne sont comptés que via un raccourcisseur (Dub / Short.io / Kutt) | compose officiel (variables `DUB_*`, `SHORT_IO_*`, `KUTT_*`) | section commentée dans `.env.example` |
| Postiz est multi-utilisateurs (comptes, Team) ; `DISABLE_REGISTRATION` ferme l'inscription | doc Postiz | à passer à `true` après ton compte |
| Table des posts : `"Post"` avec `publishDate`, `state` (`QUEUE`/`PUBLISHED`/`ERROR`/`DRAFT`), `deletedAt`, `parentPostId` | schéma Prisma Postiz | requête « posts en retard » dans `start` — **si la requête échoue, le schéma a changé** : `docker exec -it postiz-postgres psql -U postiz-user -d postiz-db-local -c '\d "Post"'` |

**Non vérifié (à observer au premier cas réel)** : ce que Postiz fait lui-même d'un post dont l'heure est passée pendant que le PC était éteint (publication immédiate au redémarrage ? passage en `ERROR` ?). Note le résultat ici quand ça arrive.

## 2. Poids mesurés (2026-09-16, `docker manifest inspect` puis `docker images` après pull)

| Image | Téléchargé (compressé) | Sur disque |
|---|---|---|
| `ghcr.io/gitroomhq/postiz-app:latest` | 1 018 MB | **5,66 GB** |
| `temporalio/auto-setup:1.28.1` | 205 MB | 745 MB |
| `postgres:17-alpine` (utilisé par 2 services, 1 seul pull) | 112 MB | 424 MB |
| `redis:7.2` | 41 MB | 169 MB |
| `alpine/openssl` | ~10 MB | 23 MB |
| **Total** | **~1,4 GB** | **~7 GB** |

L'estimation initiale « 3,5–4 GB sur disque » était fausse : l'image Postiz se décompresse ×5,5.
RAM au repos : non mesurée encore (attendu ~1–1,5 GB). Note la valeur réelle ici : `docker stats --no-stream`.

## 3. Faits vérifiés sur Tailscale Funnel (2026-09-15)

| Fait | Source |
|---|---|
| Funnel est disponible sur **tous les plans**, gratuit inclus | [kb/1223](https://tailscale.com/kb/1223/funnel) |
| Ports publics possibles : **443, 8443, 10000** uniquement | idem |
| Prérequis console : **MagicDNS** + **HTTPS Certificates** activés, attribut `funnel` dans `nodeAttrs` de la policy | idem |
| Bande passante **limitée, non configurable** (suffisante pour des vidéos de quelques dizaines de MB) | idem |
| `tailscale status --json` → `Self.DNSName` renvoie le nom **avec un point final** (`closify.tail68b6a3.ts.net.`) | testé sur cette machine | les scripts font `TrimEnd('.')` / `${name%.}` |
| CLI Windows : `C:\Program Files\Tailscale\tailscale.exe` (pas forcément dans le PATH) | testé | chemin en dur dans `common.ps1` |
| L'URL publique est stable tant que le **nom de machine** et le tailnet ne changent pas | doc | changer de PC = nouvelle URL = redirect URIs à refaire |

**Non vérifié** : `tailscale funnel --bg --set-path /legal <dossier>` pour servir un dossier statique (la doc `serve` l'annonce ; à confirmer au premier `start` avec `tailscale funnel status`). Si ça ne marche pas : servir `legal/` via un mini conteneur nginx sur un autre port et `--set-path /legal 8081`.

## 4. Pièges payés pendant la construction

### PowerShell 5.1 + UTF-8 sans BOM = script cassé (2026-09-16)
Symptôme : `ParseFile` échoue avec « The string is missing the terminator » ou « configuration name 'terminÃ©e.' is not valid », alors que le script est correct.
Cause : Windows PowerShell 5.1 lit un `.ps1` **sans BOM en ANSI (cp1252)**. Le tiret cadratin « — » (UTF-8 `E2 80 94`) contient l'octet `0x94` = « ” » en cp1252, que PowerShell prend pour un guillemet fermant. Même chose pour « … » et tout caractère dont l'encodage UTF-8 contient `0x91–0x94`.
Fix appliqué : tous les `.ps1` sont enregistrés en **UTF-8 avec BOM**. Si tu édites un `.ps1` avec un éditeur qui retire le BOM, re-sauvegarde-le « UTF-8 with BOM ». Vérif rapide :
```powershell
[IO.File]::ReadAllBytes('scripts\setup.ps1')[0..2] -join ','   # attendu : 239,187,191
```

### PowerShell 5.1 abîme les flux binaires dans les pipes
Ne jamais faire `pg_dump | openssl` ni `docker exec ... | Set-Content` avec du binaire : PowerShell convertit en texte. Les scripts passent **par des fichiers** (`pg_dump -f` dans le conteneur, `docker cp`, puis `openssl -in/-out` sur un dossier monté en `-v`).

### `docker system prune` supprime les images
Le rapport initial proposait un « nettoyage » à la fermeture : ça aurait effacé 7 GB d'images et forcé 1,4 GB de re-téléchargement à chaque lancement. `stop` ne fait que `docker image prune -f` (images orphelines) et `docker builder prune -f`.

### Port dynamique = OAuth cassé
Le port fait partie des URLs déclarées chez chaque réseau (via `FUNNEL_HOST`, port 443 côté public). Le port local 4007 est fixe ; `start` refuse de démarrer s'il est occupé plutôt que d'en choisir un autre en silence.

### Synchroniser `data/postgres` par git = corruption
Le dossier de données Postgres est binaire et en cours d'écriture : on ne le versionne jamais. Seul un `pg_dump` (cohérent) est sauvegardé.

### Nom d'utilisateur GitHub
Le compte `gh` connecté est **`Njikam-nganzie-moustapha`** (pas l'adresse mail). L'URL de clone du README a été corrigée en conséquence.

### `docker compose pull` sans `.env`
Le compose déclare `env_file: .env` : sans ce fichier, `pull`/`config` refusent de tourner. Pour un pull « à blanc », copier `.env.example` en fichier temporaire et passer `--env-file`. `setup` crée le vrai `.env` avant tout.

### Interpolation `${VAR}` dans `.env`
Compose v5 interpole bien `MAIN_URL=https://${FUNNEL_HOST}` dans un `env_file` (vérifié avec `docker compose config`). `Read-DotEnv`/`read_dotenv` dans les scripts font la même résolution pour leur propre usage.

## 5. Guide de débogage

### Postiz ne devient pas `healthy`
```powershell
docker compose ps                      # lequel est unhealthy ?
docker compose logs --tail 100 postiz
docker compose logs --tail 50 temporal
```
- `temporal` en boucle → vérifier `temporal-postgresql` (`pg_isready -U temporal`) et que `dynamicconfig/development-sql.yaml` existe.
- Erreur `JWT_SECRET` / `DATABASE_URL` vide → `.env` incomplet, relancer `setup`.
- Premier démarrage : les migrations Prisma prennent 1–3 min ; `start_period` est de 120 s.

### L'URL publique ne répond pas
```powershell
tailscale funnel status                # doit montrer https://<pc>.<tailnet>.ts.net → 127.0.0.1:4007
curl.exe -I http://127.0.0.1:4007      # l'app répond en local ?
```
- « funnel not enabled » → console Tailscale : MagicDNS, HTTPS, `nodeAttrs` funnel.
- DNS : jusqu'à 10 min de propagation la première fois.
- Testé depuis un téléphone en 4G (pas depuis le tailnet) pour être sûr que c'est bien public.

### Un réseau refuse la connexion (OAuth)
- Redirect URI exacte : `https://<FUNNEL_HOST>/integrations/social/<réseau>` — vérifier `FUNNEL_HOST` dans `.env` vs `tailscale status`.
- Clés collées dans `.env` puis conteneur **redémarré** (`docker compose up -d postiz`) : les env ne se rechargent pas à chaud.
- Google « invalid_grant » après une semaine → app en mode Testing (voir §1).

### Un post échoue à la publication
- TikTok/Instagram : le média est-il joignable ? `https://<FUNNEL_HOST>/uploads/...` doit s'ouvrir depuis l'extérieur.
- PC éteint à l'heure prévue → `start` liste les posts en retard ; republier depuis le calendrier.
- Détail de l'erreur : `docker compose logs postiz | Select-String -Pattern error -Context 2`.

### Sauvegarde / restauration
- « mauvaise passphrase ? » → la passphrase DPAPI est liée à **ce compte Windows** ; sur une autre machine, `setup` la redemande : il faut la même que celle du backup.
- `git push` échoue → `gh auth status` ; le commit est fait localement, relancer `backup` plus tard.
- Après `restore`, comptes sociaux « à reconnecter » → `JWT_SECRET` différent de celui du backup (`restore` le réinjecte ; vérifier `.env`).
- Temporal après restore : si les posts programmés n'apparaissent plus dans le moteur, les ré-enregistrer depuis le calendrier (ouvrir/enregistrer chaque post).

### Interface Temporal (debug avancé)
```powershell
docker compose --profile debug up -d temporal-ui    # http://127.0.0.1:8080
```

## 6. Journal des découvertes (à compléter)

| Date | Découverte | Impact / fix |
|---|---|---|
| 2026-09-15 | TikTok/IG exigent un média public HTTPS → « local pur » impossible pour eux | architecture Funnel |
| 2026-09-15 | Temporal obligatoire, ES optionnel | compose allégé |
| 2026-09-16 | `.ps1` UTF-8 sans BOM cassés par « — » | BOM sur tous les .ps1 |
| 2026-09-16 | image Postiz = 5,66 GB décompressée | README corrigé (~7 GB) |
| 2026-09-16 | `Self.DNSName` a un point final | trim dans les scripts |
| 2026-09-17 | chiffrement aller-retour via `alpine/openssl` vérifié sur Windows | `Test-Crypto` OK |
