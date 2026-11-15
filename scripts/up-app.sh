#!/usr/bin/env bash
# Pull and recreate one app service (plus optional extras) on the server.
# Used by the app-deploy GitHub Actions workflow.
# Usage: up-app.sh <service> [extra_service ...]
set -euo pipefail

SCRIPTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh disable=SC1091
source "$SCRIPTS_DIR/lib.sh"

if [ $# -lt 1 ]; then
  echo "Usage: $0 <service> [extra_service ...]" >&2
  exit 1
fi

service=$1
shift

for s in "$service" "$@"; do
  echo "==> Pulling $s"
  compose pull "$s"
done

echo "==> Recreating $service"
compose up -d --no-deps --force-recreate --wait "$service"
if [ $# -gt 0 ]; then
  echo "==> Recreating extras: $*"
  compose up -d --no-deps "$@"
fi
compose ps "$service" "$@"
