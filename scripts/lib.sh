#!/usr/bin/env bash
# Shared helpers. Sourced by apply.sh, bootstrap.sh, up-app.sh, new-app.sh.
# Not meant to be executed directly.

SCRIPTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEPLOY_ROOT=$(cd "$SCRIPTS_DIR/.." && pwd)
ENV_DIR=${ENV_DIR:-/opt/apps/env}
PROJECT=deploy
GHCR_OWNER=${GHCR_OWNER:-kapillohani023}

compose_files() {
  local files=( -f "$DEPLOY_ROOT/compose.yml" )
  local f
  for f in "$DEPLOY_ROOT"/apps/*/compose.yml; do
    [ -f "$f" ] && files+=( -f "$f" )
  done
  printf '%s\n' "${files[@]}"
}

compose() {
  if [ ! -f "$ENV_DIR/.env" ]; then
    echo "Missing $ENV_DIR/.env (POSTGRES_PASSWORD). Run scripts/bootstrap.sh first." >&2
    return 1
  fi
  # Word-splitting of compose_files is intentional: it prints -f /path pairs.
  # shellcheck disable=SC2046
  docker compose --project-name "$PROJECT" --env-file "$ENV_DIR/.env" $(compose_files) "$@"
}

app_names() {
  local d
  for d in "$DEPLOY_ROOT"/apps/*; do
    [ -d "$d" ] && [ -f "$d/compose.yml" ] && basename "$d"
  done
}

app_db_name() {
  local app=$1
  local marker="$DEPLOY_ROOT/apps/$app/db"
  if [ ! -e "$marker" ]; then
    return 1
  fi
  if [ -s "$marker" ]; then
    tr -d '[:space:]' < "$marker"
  else
    echo "${app//-/_}"
  fi
}

app_extra_services() {
  local app=$1
  local f="$DEPLOY_ROOT/apps/$app/extra-services"
  if [ -s "$f" ]; then
    # shellcheck disable=SC2002
    cat "$f" | tr -s '[:space:]' ' ' | xargs
  fi
}

app_image() {
  local app=$1
  echo "ghcr.io/${GHCR_OWNER}/${app}:latest"
}

image_present() {
  docker image inspect "$1" >/dev/null 2>&1
}

# URL-safe splice of POSTGRES_PASSWORD into DATABASE_URL placeholders.
splice_db_password() {
  local file=$1
  local password=$2
  [ -f "$file" ] || return 0
  if grep -q 'CHANGE_ME@postgres' "$file"; then
    sed -i "s|CHANGE_ME@postgres|${password}@postgres|g" "$file"
    echo "    filled DATABASE_URL password in $file"
  fi
}

env_password() {
  awk -F= '/^POSTGRES_PASSWORD=/{print substr($0, index($0,"=")+1); exit}' "$ENV_DIR/.env"
}
