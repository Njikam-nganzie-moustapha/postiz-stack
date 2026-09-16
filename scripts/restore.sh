#!/usr/bin/env bash
# Restaure la dernière sauvegarde sur CE PC. Équivalent de restore.ps1.
#   bash scripts/restore.sh [--force]
source "$(dirname "$0")/lib/common.sh"

FORCE=""; [[ "${1:-}" == "--force" ]] && FORCE=1

assert_docker
read_dotenv
assert_backups_repo
PASS="$(get_passphrase)"

step "Récupération de la dernière sauvegarde"
( cd "$BACKUPS_REPO" && git pull -q origin HEAD 2>/dev/null || true )
LATEST="$BACKUPS_REPO/latest"
[[ -f "$LATEST/postiz.dump.enc" ]] || fail "Aucune sauvegarde dans $LATEST"
cat "$LATEST/manifest.json"; echo

DB_DIR="$DATA_DIR/postgres"
if [[ -d "$DB_DIR" && -n "$(ls -A "$DB_DIR" 2>/dev/null)" && -z "$FORCE" ]]; then
  fail "data/postgres n'est pas vide. Relance avec --force pour ÉCRASER la base actuelle (backup.sh avant si elle compte)."
fi

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

step "Déchiffrement"
for f in "$LATEST"/*.enc; do
  n="$(basename "$f")"; cp "$f" "$WORK/$n"
  unprotect_file "$WORK" "$n" "${n%.enc}" "$PASS"; rm -f "$WORK/$n"
done

step "Secrets"
# shellcheck disable=SC1091
S_JWT="$(sed -n 's/^JWT_SECRET=//p' "$WORK/secrets.env")"; S_HOST="$(sed -n 's/^FUNNEL_HOST=//p' "$WORK/secrets.env")"
if [[ -n "$S_JWT" && "$S_JWT" != "$JWT_SECRET" ]]; then set_dotenv_value JWT_SECRET "$S_JWT"; ok "JWT_SECRET restauré"; fi
if [[ -n "$S_HOST" && "$S_HOST" != "$FUNNEL_HOST" ]]; then
  warn "La sauvegarde vient de https://$S_HOST, ce PC est https://$FUNNEL_HOST."
  warn "Mets à jour la redirect URI chez chaque réseau social, sinon 'reconnecter un compte' échouera."
fi

step "Bases de données"
if [[ -n "$FORCE" ]]; then compose down; rm -rf "$DB_DIR" "$DATA_DIR/temporal-postgres"; fi
compose up -d postiz-postgres temporal-postgresql
compose exec -T postiz-postgres sh -c 'until pg_isready -q; do sleep 1; done'
docker cp "$WORK/postiz.dump" postiz-postgres:/tmp/postiz.dump >/dev/null
docker exec postiz-postgres pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists --no-owner /tmp/postiz.dump \
  || warn "pg_restore a signalé des avertissements (souvent bénins avec --clean)."
docker exec postiz-postgres rm -f /tmp/postiz.dump
ok "Base Postiz restaurée"

if [[ -f "$WORK/temporal.sql" ]]; then
  compose exec -T temporal-postgresql sh -c 'until pg_isready -q -U temporal; do sleep 1; done'
  docker cp "$WORK/temporal.sql" temporal-postgresql:/tmp/temporal.sql >/dev/null
  docker exec temporal-postgresql psql -U temporal -q -f /tmp/temporal.sql >/dev/null 2>&1 || true
  docker exec temporal-postgresql rm -f /tmp/temporal.sql
  ok "Base Temporal restaurée"
fi

if [[ -f "$WORK/uploads.tar.gz" ]]; then
  step "Médias"; mkdir -p "$DATA_DIR/uploads"
  docker run --rm --entrypoint tar -v "$DATA_DIR/uploads:/u" -v "$WORK:/work:ro" "$OPENSSL_IMAGE" xzf /work/uploads.tar.gz -C /u
  ok "Médias restaurés dans data/uploads"
else
  warn "Pas de médias dans la sauvegarde : les posts programmés avec une vidéo devront être re-uploadés."
fi

compose stop
printf '\n\033[32mRestauration terminée. Lance bash scripts/start.sh\033[0m\n\n'
