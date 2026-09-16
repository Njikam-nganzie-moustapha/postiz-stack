#!/usr/bin/env bash
# Première configuration (Linux / macOS). Équivalent de setup.ps1.
#   bash scripts/setup.sh            |   bash scripts/setup.sh --skip-pull
source "$(dirname "$0")/lib/common.sh"

SKIP_PULL=""; [[ "${1:-}" == "--skip-pull" ]] && SKIP_PULL=1

cat <<'EOF'

  Postiz — configuration initiale
  ==============================
  Poids à prévoir : ~1,4 GB à télécharger, ~7 GB sur disque, ~1,5 GB de RAM en marche.

EOF

step "1/6 Vérifications"
assert_docker
FUNNEL_HOST_NOW="$(get_funnel_host)"
ok "Tailscale connecté — nom public : $FUNNEL_HOST_NOW"

step "2/6 Fichier .env"
if [[ -f "$ENV_FILE" ]]; then
  warn ".env existe déjà, il est conservé (supprime-le pour repartir de zéro)."
else
  cp "$ENV_EXAMPLE" "$ENV_FILE"
  set_dotenv_value FUNNEL_HOST "$FUNNEL_HOST_NOW"
  set_dotenv_value JWT_SECRET "$(head -c 32 /dev/urandom | base64 | tr -d '/+=\n')"
  ok ".env créé (FUNNEL_HOST et JWT_SECRET remplis)"
fi
read_dotenv
if [[ "$FUNNEL_HOST" != "$FUNNEL_HOST_NOW" ]]; then
  warn "FUNNEL_HOST dans .env ($FUNNEL_HOST) ≠ nom Tailscale actuel ($FUNNEL_HOST_NOW)."
  warn "Si tu as changé de PC, mets à jour FUNNEL_HOST et les redirect URIs de chaque réseau."
fi

step "3/6 Passphrase des sauvegardes"
HAD_PASS=""; [[ -f "$PASS_FILE" ]] && HAD_PASS=1
PASS="$(get_passphrase)"
[[ -n "$HAD_PASS" ]] && ok "Passphrase déjà enregistrée"

step "4/6 Dépôt GitHub privé des sauvegardes"
assert_backups_repo

step "5/6 Images Docker"
if [[ -n "$SKIP_PULL" ]]; then
  warn "Téléchargement sauté (--skip-pull). start.sh le fera au premier lancement."
else
  echo "    Téléchargement (~1,4 GB)… tu peux laisser tourner."
  compose pull
  docker pull "$OPENSSL_IMAGE" >/dev/null
  test_crypto "$PASS"
fi

step "6/6 Sauvegarde existante ?"
if [[ -f "$BACKUPS_REPO/latest/postiz.dump.enc" && ! -d "$DATA_DIR/postgres" ]]; then
  echo "    Une sauvegarde existe dans ton dépôt et cette machine est vierge."
  read -r -p "    Restaurer maintenant ? (o/N) " r
  [[ "$r" =~ ^[oOyY] ]] && bash "$SCRIPT_DIR/restore.sh"
else
  ok "Rien à restaurer"
fi

cat <<EOF

  Configuration terminée.

  Avant le premier start, dans la console Tailscale (https://login.tailscale.com/admin) :
    - DNS  : MagicDNS activé, HTTPS Certificates activé
    - Access Controls : ajouter
        "nodeAttrs": [ { "target": ["autogroup:member"], "attr": ["funnel"] } ]

  Ensuite :  bash scripts/start.sh
  Ton Postiz sera à : https://$FUNNEL_HOST_NOW

EOF
