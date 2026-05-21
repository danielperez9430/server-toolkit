#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Update Caddy (with Cloudflare DNS plugin) to the latest version
# ==============================================================================

CADDY_BIN="/usr/local/bin/caddy"
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT  # Always clean up temp dir on exit

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

current_version() {
  "$CADDY_BIN" version 2>/dev/null | awk '{print $1}' || echo "not installed"
}

latest_version() {
  curl -fsSL "https://api.github.com/repos/caddyserver/caddy/releases/latest" \
    | grep '"tag_name"' \
    | head -1 \
    | cut -d '"' -f4
}

# ------------------------------------------------------------------------------
# Pre-flight checks
# ------------------------------------------------------------------------------

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: This script must be run as root (or via sudo)." >&2
  exit 1
fi

if ! command -v xcaddy &>/dev/null; then
  echo "ERROR: xcaddy is not installed. Run the setup script first." >&2
  exit 1
fi

# ------------------------------------------------------------------------------
# Version check
# ------------------------------------------------------------------------------

echo ">>> Checking versions..."
CURRENT="$(current_version)"
LATEST="$(latest_version)"

echo "    Installed : $CURRENT"
echo "    Latest    : $LATEST"

if [ "$CURRENT" = "$LATEST" ]; then
  echo ""
  echo "Caddy is already up to date ($CURRENT). Nothing to do."
  exit 0
fi

echo ""
echo ">>> Update available: $CURRENT → $LATEST"
echo ""

# ------------------------------------------------------------------------------
# Build new version
# ------------------------------------------------------------------------------

echo ">>> Building new Caddy binary in $BUILD_DIR ..."
cd "$BUILD_DIR"
xcaddy build --with github.com/caddy-dns/cloudflare

# ------------------------------------------------------------------------------
# Validate the new binary before replacing the old one
# ------------------------------------------------------------------------------

echo ">>> Validating new binary..."
NEW_BIN="$BUILD_DIR/caddy"
NEW_VERSION="$("$NEW_BIN" version 2>/dev/null | awk '{print $1}')"

if [ -z "$NEW_VERSION" ]; then
  echo "ERROR: New binary failed version check. Aborting — existing installation untouched." >&2
  exit 1
fi

echo "    New binary reports version: $NEW_VERSION"

# ------------------------------------------------------------------------------
# Swap binaries (with backup)
# ------------------------------------------------------------------------------

BACKUP_BIN="${CADDY_BIN}.bak"

echo ">>> Backing up current binary to $BACKUP_BIN ..."
cp "$CADDY_BIN" "$BACKUP_BIN"

echo ">>> Installing new binary..."
mv "$NEW_BIN" "$CADDY_BIN"
chmod +x "$CADDY_BIN"

# ------------------------------------------------------------------------------
# Reload or restart service
# ------------------------------------------------------------------------------

if systemctl is-active --quiet caddy; then
  echo ">>> Reloading Caddy service (zero-downtime)..."
  if ! systemctl reload caddy; then
    echo "WARNING: Reload failed — attempting full restart..."
    systemctl restart caddy
  fi
else
  echo ">>> Caddy service is not running. Skipping reload."
  echo "    Start it manually with: sudo systemctl start caddy"
fi

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------

echo ""
echo "======================================================"
echo " Caddy updated successfully!"
echo "======================================================"
echo ""
echo "  Previous version : $CURRENT"
echo "  New version      : $NEW_VERSION"
echo "  Backup saved at  : $BACKUP_BIN"
echo ""
echo " If something goes wrong, roll back with:"
echo "   sudo systemctl stop caddy"
echo "   sudo cp $BACKUP_BIN $CADDY_BIN"
echo "   sudo systemctl start caddy"
echo ""
