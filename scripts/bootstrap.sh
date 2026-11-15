#!/usr/bin/env bash
# One-time (and idempotent) bootstrap for a fresh Ubuntu 24.04 instance.
# Installs Docker + Compose plugin, creates /opt/deploy and /opt/apps/env,
# generates POSTGRES_PASSWORD if missing, syncs this tree into /opt/deploy
# when run from a copy (git clone or rsync dest), then runs apply.sh.
#
#   sudo bash /path/to/deploy/scripts/bootstrap.sh
set -euo pipefail

SCRIPTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh disable=SC1091
source "$SCRIPTS_DIR/lib.sh"

if [ "$(id -u)" -ne 0 ]; then
  echo "Re-run as root: sudo bash $0" >&2
  exit 1
fi

DEPLOY_USER="${SUDO_USER:-${DEPLOY_USER:-ubuntu}}"
if ! id "$DEPLOY_USER" >/dev/null 2>&1; then
  echo "Deploy user '$DEPLOY_USER' does not exist. Set DEPLOY_USER=... and re-run." >&2
  exit 1
fi

echo "==> Deploy user: $DEPLOY_USER"

install_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    echo "==> Docker and Compose already installed: $(docker compose version)"
    return
  fi

  if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
  fi

  case "${ID:-}" in
    ubuntu|debian)
      echo "==> Installing Docker Engine + Compose plugin from Docker's repo"
      apt-get update -y
      apt-get install -y ca-certificates curl gnupg rsync
      install -m 0755 -d /etc/apt/keyrings
      if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
        curl -fsSL "https://download.docker.com/linux/${ID}/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
      fi
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" \
        > /etc/apt/sources.list.d/docker.list
      apt-get update -y
      apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      ;;
    *)
      echo "Unsupported OS (${ID:-unknown}). Install Docker Engine and the Compose plugin (>= 2.20), then re-run." >&2
      exit 1
      ;;
  esac
}

install_docker
systemctl enable --now docker
usermod -aG docker "$DEPLOY_USER" || true

TARGET=/opt/deploy
mkdir -p "$TARGET" "$ENV_DIR"
# If this tree is not already /opt/deploy, sync it there (git clone or a
# temporary rsync dest like /tmp/deploy-src).
if [ "$DEPLOY_ROOT" != "$TARGET" ]; then
  echo "==> Syncing $DEPLOY_ROOT -> $TARGET"
  rsync -a --delete \
    --exclude '.git/' \
    --exclude '.github/' \
    --exclude 'templates/' \
    --exclude 'examples/' \
    --exclude 'README.md' \
    --exclude 'STEPS.md' \
    --exclude '.gitignore' \
    "$DEPLOY_ROOT"/ "$TARGET"/
fi
chown -R "$DEPLOY_USER":"$DEPLOY_USER" "$TARGET" "$ENV_DIR"
chmod 700 "$ENV_DIR"

ENV_FILE="$ENV_DIR/.env"
if [ ! -f "$ENV_FILE" ]; then
  cat > "$ENV_FILE" <<'ENVEOF'
POSTGRES_PASSWORD=CHANGE_ME
CADDY_EMAIL=kapillohani023@gmail.com
ENVEOF
  chown "$DEPLOY_USER":"$DEPLOY_USER" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
fi
if grep -qE '^POSTGRES_PASSWORD=(CHANGE_ME)?$' "$ENV_FILE"; then
  PW=$(openssl rand -hex 24)
  sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$PW|" "$ENV_FILE"
  echo "==> Generated POSTGRES_PASSWORD in $ENV_FILE"
fi

echo "==> Running apply.sh"
# docker group membership may not be active in this sudo session yet.
if su - "$DEPLOY_USER" -c "docker info" >/dev/null 2>&1; then
  su - "$DEPLOY_USER" -c "ENV_DIR=$ENV_DIR bash $TARGET/scripts/apply.sh"
else
  # Fall back to running apply as root this once; later applies run as ubuntu.
  ENV_DIR="$ENV_DIR" bash "$TARGET/scripts/apply.sh"
  chown -R "$DEPLOY_USER":"$DEPLOY_USER" "$ENV_DIR"
fi

cat <<MSG

==> Bootstrap complete.

Env files live in $ENV_DIR (never in git). Edit the app files there before
the first app-repo deploy:

  $ENV_DIR/streaks.env
  $ENV_DIR/task-to-api.env
  $ENV_DIR/portfolio.env   # nothing required

Caddy is running. If DNS is not yet pointing at this instance, Let's Encrypt
will fail until it is — then run:  bash $TARGET/scripts/apply.sh
(or just push to the deploy repo / re-run the Apply workflow).

If $DEPLOY_USER was just added to the docker group, they should log out and
back in (or newgrp docker) before running docker by hand.

MSG
