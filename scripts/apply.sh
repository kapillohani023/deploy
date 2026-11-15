#!/usr/bin/env bash
# Idempotent apply. Run on the server (as ubuntu, in the docker group).
# Ensures env file placeholders, creates missing app databases, starts
# postgres + caddy, starts only those apps whose images are already on
# the box, reloads Caddy, and prunes dangling images.
set -euo pipefail

SCRIPTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh disable=SC1091
source "$SCRIPTS_DIR/lib.sh"

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is not installed. Run scripts/bootstrap.sh first." >&2
  exit 1
fi

mkdir -p "$ENV_DIR"
chmod 700 "$ENV_DIR" 2>/dev/null || true

if [ ! -f "$ENV_DIR/.env" ]; then
  echo "Missing $ENV_DIR/.env. Run scripts/bootstrap.sh first." >&2
  exit 1
fi

PASSWORD=$(env_password)
if [ -z "$PASSWORD" ] || [ "$PASSWORD" = "CHANGE_ME" ]; then
  echo "POSTGRES_PASSWORD is empty or still CHANGE_ME in $ENV_DIR/.env" >&2
  exit 1
fi

echo "==> Ensuring per-app env files (will not overwrite existing)"
for app in $(app_names); do
  example="$DEPLOY_ROOT/apps/$app/env.example"
  dest="$ENV_DIR/$app.env"
  if [ -f "$example" ] && [ ! -f "$dest" ]; then
    cp "$example" "$dest"
    chmod 600 "$dest"
    echo "    created $dest from example"
  fi
  splice_db_password "$dest" "$PASSWORD"
done

echo "==> Starting Postgres"
compose up -d --no-deps postgres
# Wait until healthy (or at least accepting connections).
for _ in $(seq 1 30); do
  if compose exec -T postgres pg_isready -U app -d postgres >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
if ! compose exec -T postgres pg_isready -U app -d postgres >/dev/null 2>&1; then
  echo "Postgres did not become ready" >&2
  exit 1
fi

echo "==> Creating missing databases"
for app in $(app_names); do
  db=
  db=$(app_db_name "$app") || continue
  [ -n "$db" ] || continue
  exists=$(compose exec -T postgres psql -U app -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${db}'" | tr -d '[:space:]')
  if [ "$exists" = "1" ]; then
    echo "    $db already exists"
  else
    compose exec -T postgres psql -U app -d postgres -c "CREATE DATABASE ${db}"
    echo "    created database $db"
  fi
done

echo "==> Starting Caddy"
compose up -d --no-deps caddy

echo "==> Starting apps that already have images"
running=(postgres caddy)
for app in $(app_names); do
  img=$(app_image "$app")
  extras=$(app_extra_services "$app")
  if image_present "$img"; then
    echo "    up $app ${extras}"
    # shellcheck disable=SC2086
    compose up -d --no-deps "$app" $extras
    running+=("$app")
    # extras may be empty
    for s in $extras; do
      running+=("$s")
    done
  else
    echo "    skip $app (image $img not present yet; first app-repo deploy will start it)"
  fi
done

# Remove containers whose services disappeared from compose (e.g. a deleted app).
echo "==> Reconciling (remove orphans)"
compose up -d --remove-orphans --no-deps "${running[@]}"

if compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
  echo "==> Caddy reloaded"
else
  echo "==> Caddy reload skipped (container still starting; it will pick up the config)"
fi

docker image prune -f >/dev/null || true
echo "==> Apply complete"
compose ps
