#!/usr/bin/env bash
# Scaffold a new app under apps/<name>/.
# Usage: new-app.sh <name> <subdomain|domain> [--db] [--port N]
#   name       Compose service + GHCR image name (lowercase, e.g. my-app)
#   domain     FQDN (www.example.com) or a subdomain of kapillohani.site (e.g. blog)
#   --db       Create a Postgres database (apps/<name>/db)
#   --port N   Container listen port (default 3000)
set -euo pipefail

SCRIPTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh disable=SC1091
source "$SCRIPTS_DIR/lib.sh"

BASE_DOMAIN=${BASE_DOMAIN:-kapillohani.site}
usage() {
  echo "Usage: $0 <name> <subdomain|domain> [--db] [--port N]" >&2
  exit 1
}

[ $# -ge 2 ] || usage
NAME=$1
SHIFT_DOMAIN=$2
shift 2

if ! [[ "$NAME" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
  echo "Name must be a lowercase DNS-ish label (got: $NAME)" >&2
  exit 1
fi

WANT_DB=0
PORT=3000
while [ $# -gt 0 ]; do
  case "$1" in
    --db) WANT_DB=1; shift ;;
    --port)
      PORT=${2:-}
      [ -n "$PORT" ] || usage
      shift 2
      ;;
    *) usage ;;
  esac
done

if [[ "$SHIFT_DOMAIN" == *.* ]]; then
  DOMAIN=$SHIFT_DOMAIN
else
  DOMAIN="${SHIFT_DOMAIN}.${BASE_DOMAIN}"
fi

DIR="$DEPLOY_ROOT/apps/$NAME"
if [ -e "$DIR" ]; then
  echo "Already exists: $DIR" >&2
  exit 1
fi
mkdir -p "$DIR"

DB_NAME=${NAME//-/_}
IMAGE="ghcr.io/${GHCR_OWNER}/${NAME}:latest"

ENV_OVERRIDE=$(printf '%s' "$NAME" | tr '[:lower:]-' '[:upper:]_')
DEPENDS=""
if [ "$WANT_DB" -eq 1 ]; then
  DEPENDS=$(printf '\n    depends_on:\n      postgres:\n        condition: service_healthy')
  printf '%s\n' "$DB_NAME" > "$DIR/db"
fi

cat > "$DIR/compose.yml" <<YAML
services:
  ${NAME}:
    image: \${${ENV_OVERRIDE}_IMAGE:-${IMAGE}}
    pull_policy: missing
    restart: unless-stopped
    env_file:
      - /opt/apps/env/${NAME}.env
    expose:
      - "${PORT}"
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://127.0.0.1:${PORT}/"]
      interval: 30s
      timeout: 5s
      start_period: 40s
      retries: 3${DEPENDS}
YAML

APEX=""
if [[ "$DOMAIN" == www.* ]]; then
  APEX=${DOMAIN#www.}
  cat > "$DIR/site.caddy" <<CADDY
${DOMAIN} {
	import site_headers
	reverse_proxy ${NAME}:${PORT}
}

${APEX} {
	redir https://${DOMAIN}{uri} permanent
}
CADDY
else
  cat > "$DIR/site.caddy" <<CADDY
${DOMAIN} {
	import site_headers
	reverse_proxy ${NAME}:${PORT}
}
CADDY
fi

{
  echo "# Runtime env for ${NAME}. Copied to /opt/apps/env/${NAME}.env on apply (never overwritten)."
  echo "NODE_ENV=production"
  echo "PORT=${PORT}"
  if [ "$WANT_DB" -eq 1 ]; then
    echo "DATABASE_URL=postgresql://app:CHANGE_ME@postgres:5432/${DB_NAME}?schema=public"
  fi
} > "$DIR/env.example"

cat > "$DIR/source" <<SRC
REPO=https://github.com/${GHCR_OWNER}/${NAME}.git
BRANCH=main
SRC

SCHEME="https://${DOMAIN}"
cat <<MSG

==> Scaffolded $DIR

  compose.yml     service ${NAME}, image ${IMAGE}
  site.caddy      ${DOMAIN}${WANT_DB:+
  db              database ${DB_NAME}}
  env.example     copied to /opt/apps/env/${NAME}.env on next apply

Next steps:

1. DNS: add an A record for ${DOMAIN}${APEX:+ and ${APEX}} to the Elastic IP.
2. In the app GitHub repo, copy a Dockerfile from templates/ (next-bun-prisma or next-npm)
   plus templates/docker-entrypoint.sh if you use Prisma, and templates/dockerignore.
3. Copy examples/app-deploy-caller.yml to the app repo as .github/workflows/deploy.yml,
   set the service name to "${NAME}", and add repo secrets EC2_HOST, EC2_USER, EC2_SSH_KEY.
   Also enable Actions access on kapillohani023/deploy (see README).
   Or copy templates/deploy.yml for a self-contained workflow that does not use workflow_call.
4. Commit this app folder and apply it on the server (git pull in /opt/deploy, or
   the Apply workflow when Actions is available). Then either run
   ./scripts/manual-deploy.sh ${NAME} or, when Actions works, push main of the
   *app* repo to build and start the container.
5. Fill /opt/apps/env/${NAME}.env on the server (AUTH / API keys as needed).
   Public URL is ${SCHEME}.

MSG
