#!/usr/bin/env bash
# Idempotent. Ensures a swap file exists (default 4GiB at /swapfile).
# Next.js production builds on a t3.small (2 GiB RAM) will OOM without this.
#
#   sudo bash scripts/add-swap.sh        # 4 GiB
#   sudo bash scripts/add-swap.sh 2      # 2 GiB
set -euo pipefail

SIZE_GB=${1:-4}
SWAPFILE=${SWAPFILE:-/swapfile}
# Require at least 2 GiB of swap before we consider the host "ok".
MIN_KB=$((2 * 1024 * 1024))

if [ "$(id -u)" -ne 0 ]; then
  echo "Re-run as root: sudo bash $0" >&2
  exit 1
fi

if ! [[ "$SIZE_GB" =~ ^[0-9]+$ ]] || [ "$SIZE_GB" -lt 1 ]; then
  echo "SIZE_GB must be a positive integer (got: $SIZE_GB)" >&2
  exit 1
fi

swap_kb() {
  awk '/SwapTotal:/ {print $2}' /proc/meminfo
}

CURRENT_KB=$(swap_kb)
if [ "${CURRENT_KB:-0}" -ge "$MIN_KB" ]; then
  echo "==> Swap already present: ${CURRENT_KB} kB"
  swapon --show || true
  exit 0
fi

if [ -f "$SWAPFILE" ]; then
  echo "==> Found $SWAPFILE; enabling if needed"
else
  echo "==> Creating ${SIZE_GB}GiB swap file at $SWAPFILE"
  # fallocate is fast on ext4; dd works if fallocate is unsupported.
  if ! fallocate -l "${SIZE_GB}G" "$SWAPFILE" 2>/dev/null; then
    dd if=/dev/zero of="$SWAPFILE" bs=1M count=$((SIZE_GB * 1024)) status=progress
  fi
  chmod 600 "$SWAPFILE"
  mkswap "$SWAPFILE"
fi

if ! grep -q "^${SWAPFILE} " /proc/swaps 2>/dev/null; then
  swapon "$SWAPFILE"
fi

if ! grep -q "^${SWAPFILE} " /etc/fstab 2>/dev/null; then
  echo "$SWAPFILE none swap sw 0 0" >> /etc/fstab
  echo "==> Added $SWAPFILE to /etc/fstab"
fi

echo "==> Swap ready"
swapon --show
free -h
