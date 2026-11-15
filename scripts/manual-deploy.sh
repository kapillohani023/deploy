#!/usr/bin/env bash
# Build app images on this machine from their public GitHub repos and start
# them. No GitHub Actions or GHCR credentials required.
#
# Usage:
#   ./scripts/manual-deploy.sh <app>     # one app, e.g. streaks
#   ./scripts/manual-deploy.sh all
#
# For each apps/<name>/source (REPO, BRANCH, optional BUILD_ARGS):
#   clone/fetch into /opt/src/<name>, docker build -t ghcr.io/.../<name>:latest,
#   then up-app.sh --no-pull (so compose will not contact GHCR).
set -euo pipefail

SCRIPTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh disable=SC1091
source "$SCRIPTS_DIR/lib.sh"

SRC_ROOT=${SRC_ROOT:-/opt/src}
MIN_SWAP_KB=$((2 * 1024 * 1024))

usage() {
  echo "Usage: $0 <app|all>" >&2
  echo "  Known apps: $(app_names | tr '\n' ' ')" >&2
  exit 1
}

[ $# -eq 1 ] || usage
TARGET=$1

# --- helpers ---

read_source() {
  # Sets REPO, BRANCH, BUILD_ARGS, DOCKERFILE, CONTEXT for $1.
  local app=$1
  local file="$DEPLOY_ROOT/apps/$app/source"
  REPO="https://github.com/${GHCR_OWNER}/${app}.git"
  BRANCH=main
  BUILD_ARGS=""
  DOCKERFILE=Dockerfile
  CONTEXT=.
  [ -f "$file" ] || return 0
  local line key value
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|\#*) continue ;;
    esac
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      REPO) REPO=$value ;;
      BRANCH) BRANCH=$value ;;
      BUILD_ARGS) BUILD_ARGS=$value ;;
      DOCKERFILE) DOCKERFILE=$value ;;
      CONTEXT) CONTEXT=$value ;;
    esac
  done < "$file"
}

env_lookup() {
  local file=$1 key=$2 value
  [ -f "$file" ] || return 0
  value=$(awk -F= -v k="$key" '
    $1 == k {
      v = substr($0, index($0, "=") + 1)
      sub(/\r$/, "", v)
      q = sprintf("%c", 39)
      if ((substr(v,1,1) == "\"" && substr(v,length(v),1) == "\"") ||
          (substr(v,1,1) == q && substr(v,length(v),1) == q)) {
        v = substr(v, 2, length(v) - 2)
      }
      print v
      exit
    }
  ' "$file")
  printf '%s' "$value"
}

ensure_src_root() {
  if [ -d "$SRC_ROOT" ] && [ -w "$SRC_ROOT" ]; then
    return 0
  fi
  if mkdir -p "$SRC_ROOT" 2>/dev/null && [ -w "$SRC_ROOT" ]; then
    return 0
  fi
  if command -v sudo >/dev/null 2>&1; then
    sudo mkdir -p "$SRC_ROOT"
    sudo chown "$(id -u):$(id -g)" "$SRC_ROOT"
    return 0
  fi
  echo "Cannot create $SRC_ROOT. Run: sudo mkdir -p $SRC_ROOT && sudo chown \"\$USER:\$USER\" $SRC_ROOT" >&2
  exit 1
}

sync_repo() {
  local app=$1 dest=$2
  if [ -d "$dest/.git" ]; then
    echo "==> Fetching $REPO ($BRANCH) into $dest"
    git -C "$dest" remote set-url origin "$REPO"
    git -C "$dest" fetch --depth 1 origin "$BRANCH"
    git -C "$dest" checkout -f --detach "FETCH_HEAD"
  else
    echo "==> Cloning $REPO ($BRANCH) into $dest"
    rm -rf "$dest"
    git clone --depth 1 --branch "$BRANCH" "$REPO" "$dest"
  fi
  echo "    at $(git -C "$dest" log -1 --format='%h %s')"
}

build_image() {
  local app=$1 dest=$2
  local image
  image=$(app_image "$app")
  local envfile="$ENV_DIR/$app.env"
  local -a build_args=()
  local key value
  # shellcheck disable=SC2086
  for key in $BUILD_ARGS; do
    [ -n "$key" ] || continue
    value=$(env_lookup "$envfile" "$key")
    if [ -z "$value" ]; then
      echo "BUILD_ARGS key $key is empty or missing in $envfile" >&2
      exit 1
    fi
    build_args+=(--build-arg "$key=$value")
    echo "    build-arg $key (from $envfile)"
  done
  echo "==> Building $image (BuildKit)"
  # shellcheck disable=SC2164
  cd "$dest"
  DOCKER_BUILDKIT=1 docker build \
    -f "$DOCKERFILE" \
    -t "$image" \
    "${build_args[@]}" \
    "$CONTEXT"
}

deploy_one() {
  local app=$1
  if [ ! -f "$DEPLOY_ROOT/apps/$app/compose.yml" ]; then
    echo "Unknown app: $app" >&2
    usage
  fi
  read_source "$app"
  local dest="$SRC_ROOT/$app"
  echo
  echo "======== $app ========"
  sync_repo "$app" "$dest"
  build_image "$app" "$dest"
  local extras
  extras=$(app_extra_services "$app")
  echo "==> Starting $app ${extras}"
  # shellcheck disable=SC2086
  bash "$SCRIPTS_DIR/up-app.sh" --no-pull "$app" $extras
}

# --- preflight ---

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is not installed. Run scripts/bootstrap.sh first." >&2
  exit 1
fi
if ! command -v git >/dev/null 2>&1; then
  echo "git is required (sudo apt-get install -y git)." >&2
  exit 1
fi

SWAP_KB=$(awk '/SwapTotal:/ {print $2}' /proc/meminfo)
if [ "${SWAP_KB:-0}" -lt "$MIN_SWAP_KB" ]; then
  echo "Warning: swap is ${SWAP_KB:-0} kB (need >= 2 GiB). Next.js builds on a t3.small often OOM."
  echo "         Run:  sudo bash $SCRIPTS_DIR/add-swap.sh"
  echo
fi

ensure_src_root

# --- select apps ---
apps=()
if [ "$TARGET" = "all" ]; then
  # shellcheck disable=SC2207
  apps=($(app_names))
else
  apps=("$TARGET")
fi
[ ${#apps[@]} -gt 0 ] || usage

for app in "${apps[@]}"; do
  deploy_one "$app"
  # Different apps do not share a useful build cache; free disk on small volumes.
  if [ "$TARGET" = "all" ]; then
    docker builder prune -f >/dev/null || true
  fi
done

if compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
  echo "==> Caddy reloaded"
else
  echo "==> Caddy reload skipped (container still starting; run apply.sh if Caddy is down)"
fi

echo
echo "==> Manual deploy complete"
compose ps
