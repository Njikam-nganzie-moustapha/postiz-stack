#!/usr/bin/env bash
# Sauvegarde chiffrée → dépôt GitHub privé. Équivalent de backup.ps1.
#   bash scripts/backup.sh [--with-uploads] [--no-push] [--keep N]
source "$(dirname "$0")/lib/common.sh"

WITH_UPLOADS=""; NO_PUSH=""; KEEP=30
while [[ $# -gt 0 ]]; do case "$1" in
  --with-uploads) WITH_UPLOADS=1;; --no-push) NO_PUSH=1;; --keep) KEEP="$2"; shift;; *) fail "option inconnue : $1";; esac; shift; done

assert_docker
read_dotenv
container_running postiz-postgres || fail "postiz-postgres n'est pas démarré : rien à sauvegarder."
assert_backups_repo
PASS="$(get_passphrase)"

TS="$(date +%Y%m%d-%H%M%S)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

step "Dump des bases"
docker exec postiz-postgres pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc -f /tmp/postiz.dump || fail "pg_dump Postiz échoué"
docker cp postiz-postgres:/tmp/postiz.dump "$WORK/postiz.dump" >/dev/null; docker exec postiz-postgres rm -f /tmp/postiz.dump
FILES=(postiz.dump secrets.env)
if container_running temporal-postgresql; then
  docker exec temporal-postgresql pg_dumpall -U temporal -f /tmp/temporal.sql || fail "pg_dumpall Temporal échoué"
  docker cp temporal-postgresql:/tmp/temporal.sql "$WORK/temporal.sql" >/dev/null; docker exec temporal-postgresql rm -f /tmp/temporal.sql
  FILES+=(temporal.sql)
else warn "temporal-postgresql arrêté : base Temporal non sauvegardée"; fi
printf 'JWT_SECRET=%s\nFUNNEL_HOST=%s\n' "$JWT_SECRET" "$FUNNEL_HOST" > "$WORK/secrets.env"

if [[ -n "$WITH_UPLOADS" ]]; then
  step "Archive des médias (data/uploads)"
  docker run --rm --entrypoint tar -v "$DATA_DIR/uploads:/u:ro" -v "$WORK:/work" "$OPENSSL_IMAGE" czf /work/uploads.tar.gz -C /u . || fail "Archive des médias échouée"
  FILES+=(uploads.tar.gz)
fi

step "Chiffrement"
for f in "${FILES[@]}"; do protect_file "$WORK" "$f" "$f.enc" "$PASS"; rm -f "$WORK/$f"; done

step "Écriture dans le dépôt"
LATEST="$BACKUPS_REPO/latest"; HIST="$BACKUPS_REPO/history/$TS"
mkdir -p "$LATEST" "$HIST"; rm -f "$LATEST"/*
for f in "${FILES[@]}"; do
  cp "$WORK/$f.enc" "$LATEST/$f.enc"
  [[ "$f" != "uploads.tar.gz" ]] && cp "$WORK/$f.enc" "$HIST/$f.enc"
done
MANIFEST="$(printf '{"date":"%s","machine":"%s","funnelHost":"%s","files":["%s"],"cipher":"aes-256-cbc pbkdf2 iter=200000 (openssl enc)"}' \
  "$(date -Iseconds)" "$(hostname)" "$FUNNEL_HOST" "$(IFS='","'; echo "${FILES[*]}")")"
printf '%s\n' "$MANIFEST" > "$LATEST/manifest.json"; printf '%s\n' "$MANIFEST" > "$HIST/manifest.json"

# rotation
ls -1d "$BACKUPS_REPO"/history/*/ 2>/dev/null | sort -r | tail -n +"$((KEEP+1))" | xargs -r rm -rf

( cd "$BACKUPS_REPO"
  git add -A
  git -c user.name=postiz-backup -c user.email=postiz-backup@localhost commit -q -m "backup $TS from $(hostname)" >/dev/null 2>&1 || true
  if [[ -n "$NO_PUSH" ]]; then ok "Commit local (pas de push)"
  else git push -q origin HEAD || fail "git push échoué. La sauvegarde est committée localement, relance backup.sh plus tard."; ok "Sauvegarde $TS poussée sur GitHub"; fi
)
