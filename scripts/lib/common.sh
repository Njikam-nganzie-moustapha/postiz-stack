#!/usr/bin/env bash
# Fonctions partagées (Linux / macOS). Chargé par : source "$(dirname "$0")/lib/common.sh"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STACK_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$STACK_DIR/.env"
ENV_EXAMPLE="$STACK_DIR/.env.example"
DATA_DIR="$STACK_DIR/data"
LEGAL_DIR="$STACK_DIR/legal"
BACKUPS_REPO="$STACK_DIR/backups-repo"
LOCAL_STATE="${XDG_CONFIG_HOME:-$HOME/.config}/postiz-stack"
PASS_FILE="$LOCAL_STATE/passphrase"
OPENSSL_IMAGE="alpine/openssl"
BACKUPS_REPO_NAME="postiz-backups"

step() { printf '\n\033[36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[32mOK  %s\033[0m\n' "$*"; }
warn() { printf '    \033[33m!!  %s\033[0m\n' "$*"; }
fail() { printf '\n\033[31mERREUR : %s\033[0m\n' "$*" >&2; exit 1; }

# --- .env ---
read_dotenv() {
  [[ -f "$ENV_FILE" ]] || fail ".env introuvable. Lance d'abord scripts/setup.sh"
  # shellcheck disable=SC1090
  set -a; source "$ENV_FILE"; set +a
}

set_dotenv_value() {
  local key="$1" value="$2"
  if grep -q "^[[:space:]]*${key}=" "$ENV_FILE"; then
    local tmp; tmp="$(mktemp)"
    awk -v k="$key" -v v="$value" 'BEGIN{FS=OFS="="} $1==k{print k"="v; next} {print}' "$ENV_FILE" > "$tmp" && mv "$tmp" "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
  fi
}

# --- Docker ---
assert_docker() {
  command -v docker >/dev/null || fail "Docker n'est pas installé : https://docs.docker.com/get-docker/"
  if ! docker info >/dev/null 2>&1; then
    warn "Docker ne répond pas, tentative de démarrage…"
    if [[ "$(uname)" == "Darwin" ]]; then open -a Docker || true; else sudo systemctl start docker || true; fi
    for _ in $(seq 1 24); do sleep 5; docker info >/dev/null 2>&1 && break; done
    docker info >/dev/null 2>&1 || fail "Docker ne répond pas après 2 min."
  fi
  ok "Docker prêt"
}

container_running() { [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || true)" == "true" ]]; }

compose() { ( cd "$STACK_DIR" && docker compose "$@" ) || fail "docker compose $* a échoué"; }

# --- Tailscale ---
tailscale_bin() {
  if command -v tailscale >/dev/null; then echo tailscale
  elif [[ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]]; then echo /Applications/Tailscale.app/Contents/MacOS/Tailscale
  else fail "Tailscale n'est pas installé : https://tailscale.com/download"; fi
}

get_funnel_host() {
  local ts; ts="$(tailscale_bin)"
  local st; st="$("$ts" status --json 2>/dev/null)" || fail "Tailscale ne répond pas. Connecte-toi."
  local state; state="$(printf '%s' "$st" | sed -n 's/.*"BackendState": *"\([^"]*\)".*/\1/p' | head -1)"
  [[ "$state" == "Running" ]] || fail "Tailscale n'est pas connecté (état : ${state:-inconnu})."
  local name
  if command -v jq >/dev/null; then name="$(printf '%s' "$st" | jq -r '.Self.DNSName')"
  else name="$(printf '%s' "$st" | tr -d '\n' | sed -n 's/.*"Self": *{[^}]*"DNSName": *"\([^"]*\)".*/\1/p')"; fi
  [[ -n "$name" && "$name" != "null" ]] || fail "Nom MagicDNS illisible. Active MagicDNS dans la console Tailscale."
  printf '%s' "${name%.}"
}

# --- Passphrase (fichier 0600, lisible uniquement par ton utilisateur) ---
get_passphrase() {
  local create="${1:-}"
  if [[ -f "$PASS_FILE" && -z "$create" ]]; then cat "$PASS_FILE"; return; fi
  echo >&2
  echo "Passphrase de chiffrement des sauvegardes." >&2
  echo "C'est la SEULE chose à ne jamais perdre : sans elle, les sauvegardes sont illisibles." >&2
  local a b
  while true; do
    read -r -s -p "Passphrase (12 caractères minimum) : " a; echo >&2
    read -r -s -p "Confirme la passphrase : " b; echo >&2
    if [[ "$a" != "$b" ]]; then warn "Les deux saisies diffèrent." >&2
    elif [[ ${#a} -lt 12 ]]; then warn "Trop courte." >&2
    else break; fi
  done
  mkdir -p "$LOCAL_STATE"; (umask 077; printf '%s' "$a" > "$PASS_FILE")
  ok "Passphrase enregistrée dans $PASS_FILE (droits 0600)" >&2
  printf '%s' "$a"
}

# --- Chiffrement via conteneur ---
_openssl() { # workdir pass args...
  local work="$1" pass="$2"; shift 2
  POSTIZ_BACKUP_PASS="$pass" docker run --rm -e POSTIZ_BACKUP_PASS -v "$work:/work" -w /work "$OPENSSL_IMAGE" "$@"
}
protect_file()   { _openssl "$1" "$4" enc -aes-256-cbc -pbkdf2 -iter 200000 -salt -pass env:POSTIZ_BACKUP_PASS -in "$2" -out "$3" || fail "Chiffrement de $2 échoué"; }
unprotect_file() { _openssl "$1" "$4" enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass env:POSTIZ_BACKUP_PASS -in "$2" -out "$3" || fail "Déchiffrement de $2 échoué : mauvaise passphrase ?"; }

test_crypto() {
  local tmp; tmp="$(mktemp -d)"
  printf 'postiz-crypto-ok' > "$tmp/plain.txt"
  protect_file "$tmp" plain.txt plain.enc "$1"
  unprotect_file "$tmp" plain.enc back.txt "$1"
  [[ "$(cat "$tmp/back.txt")" == "postiz-crypto-ok" ]] || fail "Le test de chiffrement aller-retour a échoué."
  rm -rf "$tmp"; ok "Chiffrement vérifié (aller-retour)"
}

# --- GitHub ---
assert_gh() {
  command -v gh >/dev/null || fail "GitHub CLI (gh) manquant : https://cli.github.com"
  gh auth status >/dev/null 2>&1 || fail "gh n'est pas connecté. Lance : gh auth login"
}

assert_backups_repo() {
  [[ -d "$BACKUPS_REPO/.git" ]] && return
  assert_gh
  local user; user="$(gh api user --jq .login)"
  if ! gh repo view "$user/$BACKUPS_REPO_NAME" >/dev/null 2>&1; then
    step "Création du dépôt PRIVÉ $user/$BACKUPS_REPO_NAME"
    gh repo create "$BACKUPS_REPO_NAME" --private --description "Sauvegardes chiffrées Postiz (AES-256)" >/dev/null || fail "Création impossible"
  fi
  [[ "$(gh repo view "$user/$BACKUPS_REPO_NAME" --json visibility --jq .visibility)" == "PRIVATE" ]] || fail "Le dépôt $user/$BACKUPS_REPO_NAME n'est pas privé. Rends-le privé avant de continuer."
  gh repo clone "$user/$BACKUPS_REPO_NAME" "$BACKUPS_REPO" >/dev/null || fail "Clone impossible"
  ok "Dépôt de sauvegardes prêt : $BACKUPS_REPO"
}
