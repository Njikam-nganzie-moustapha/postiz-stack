#!/usr/bin/env bash
# Arrêt propre : sauvegarde → coupe Funnel → arrête les conteneurs → nettoie les caches (images conservées).
#   bash scripts/stop.sh [--no-backup]
source "$(dirname "$0")/lib/common.sh"

NO_BACKUP=""; [[ "${1:-}" == "--no-backup" ]] && NO_BACKUP=1

if [[ -z "$NO_BACKUP" ]] && container_running postiz-postgres; then
  step "Sauvegarde avant arrêt"
  bash "$SCRIPT_DIR/backup.sh" || warn "Sauvegarde échouée — arrêt quand même."
fi

step "Fermeture de l'accès public"
"$(tailscale_bin)" funnel reset >/dev/null 2>&1 || true

step "Arrêt des conteneurs"
compose down --remove-orphans

step "Nettoyage (caches uniquement, images conservées)"
docker image prune -f >/dev/null; docker builder prune -f >/dev/null

printf '\n\033[32mPostiz arrêté.\033[0m\n\n'
