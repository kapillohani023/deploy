#!/usr/bin/env bash
# Recreate one app service (plus optional extras) on the server.
# Usage: up-app.sh [--no-pull] <service> [extra_service ...]
set -euo pipefail

SCRIPTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh disable=SC1091
source "$SCRIPTS_DIR/lib.sh"

NO_PULL=0
if [ "${1:-}" = "--no-pull" ]; then
  NO_PULL=1
  shift
fi

if [ $# -lt 1 ]; then
  echo "Usage: $0 [--no-pull] <service> [extra_service ...]" >&2
  exit 1
fi

service=$1
shift

if [ "$NO_PULL" -eq 0 ]; then
  for s in "$service" "$@"; do
    echo "==> Pulling $s"
    compose pull "$s"
  done
  PULL_FLAG=()
else
  # Main app image is already on the box (GHCR load/build). Still pull
  # extras — they are usually public sidecars (e.g. curlimages/curl).
  echo "==> Skipping registry pull for $service (--no-pull)"
  for s in "$@"; do
    echo "==> Pulling extra $s"
    compose pull "$s"
  done
  PULL_FLAG=( --pull never )
fi

echo "==> Recreating $service"
compose up -d --no-deps --force-recreate --wait "${PULL_FLAG[@]}" "$service"
if [ $# -gt 0 ]; then
  echo "==> Recreating extras: $*"
  # Extras were pulled above; don't require another registry hit.
  compose up -d --no-deps --pull never "$@"
fi
compose ps "$service" "$@"
