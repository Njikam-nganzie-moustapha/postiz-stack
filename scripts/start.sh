#!/usr/bin/env bash
# Démarre Postiz + Funnel + anti-veille + navigateur, reste au premier plan. Ctrl+C = stop.sh.
#   bash scripts/start.sh            |   bash scripts/start.sh --detach
source "$(dirname "$0")/lib/common.sh"

DETACH=""; [[ "${1:-}" == "--detach" ]] && DETACH=1

step "Vérifications"
assert_docker
read_dotenv
FUNNEL_HOST_NOW="$(get_funnel_host)"
PORT="${POSTIZ_PORT:-4007}"
[[ "$FUNNEL_HOST" == "$FUNNEL_HOST_NOW" ]] || fail "FUNNEL_HOST dans .env ($FUNNEL_HOST) ≠ nom Tailscale actuel ($FUNNEL_HOST_NOW). Corrige .env (et les redirect URIs) avant de démarrer."
[[ -n "${JWT_SECRET:-}" ]] || fail "JWT_SECRET vide dans .env. Lance scripts/setup.sh."

if command -v lsof >/dev/null && lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | grep -vq -e docker -e com.docker -e COMMAND; then
  fail "Le port $PORT est utilisé par une autre application. Ferme-la puis relance."
fi

step "Démarrage des conteneurs"
compose up -d --remove-orphans

step "Attente que Postiz soit prêt (jusqu'à 5 min au premier démarrage)"
for _ in $(seq 1 60); do
  sleep 5
  H="$(docker inspect -f '{{.State.Health.Status}}' postiz 2>/dev/null || echo starting)"
  echo "    état : $H"
  [[ "$H" == "healthy" ]] && break
done
[[ "$H" == "healthy" ]] || warn "Postiz n'est pas 'healthy'. Logs : docker compose logs -f postiz"

step "Exposition publique HTTPS (Tailscale Funnel)"
TS="$(tailscale_bin)"
"$TS" funnel --bg --set-path /legal "$LEGAL_DIR" >/dev/null 2>&1 || true
if "$TS" funnel --bg "$PORT" >/dev/null 2>&1; then
  ok "https://$FUNNEL_HOST  →  127.0.0.1:$PORT"
else
  warn "Funnel refusé. Vérifie dans la console Tailscale : MagicDNS + HTTPS activés, et l'attribut 'funnel' dans Access Controls."
fi

step "Posts en retard ?"
N="$(printf '%s' 'SELECT count(*) FROM "Post" WHERE "publishDate" < now() AND state = '"'"'QUEUE'"'"' AND "deletedAt" IS NULL AND "parentPostId" IS NULL;' \
     | docker exec -i postiz-postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tA 2>/dev/null || echo "")"
if [[ "$N" =~ ^[0-9]+$ && "$N" -gt 0 ]]; then
  warn "$N post(s) dont l'heure est passée pendant que le PC était éteint. Ouvre le calendrier et republie/reprogramme-les."
else ok "Aucun post en retard"; fi

if command -v xdg-open >/dev/null; then xdg-open "https://$FUNNEL_HOST" >/dev/null 2>&1 || true
elif command -v open >/dev/null; then open "https://$FUNNEL_HOST" || true; fi

if [[ -n "$DETACH" ]]; then
  printf '\n\033[32mPostiz tourne en arrière-plan. Pour arrêter : bash scripts/stop.sh\033[0m\n\n'; exit 0
fi

cat <<EOF

  Postiz est en ligne : https://$FUNNEL_HOST
  Mise en veille bloquée tant que ce terminal est ouvert (capot fermé = veille quand même).
  Ctrl+C ici = sauvegarde + arrêt propre.

EOF

trap 'echo; echo "Arrêt demandé…"; bash "$SCRIPT_DIR/stop.sh"; exit 0' INT TERM

wait_loop() { while container_running postiz; do sleep 10; done; warn "Le conteneur postiz s'est arrêté tout seul. Logs : docker compose logs postiz"; }
if command -v systemd-inhibit >/dev/null; then
  systemd-inhibit --what=sleep:idle --why="Postiz en service" bash -c "$(declare -f container_running wait_loop warn); wait_loop"
elif command -v caffeinate >/dev/null; then
  caffeinate -i bash -c "$(declare -f container_running wait_loop warn); wait_loop"
else
  wait_loop
fi
bash "$SCRIPT_DIR/stop.sh"
