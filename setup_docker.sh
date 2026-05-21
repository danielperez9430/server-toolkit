#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Install Docker Engine on Debian/Ubuntu
# Official method: https://docs.docker.com/engine/install/ubuntu/
#
# Usage:
#   sudo bash setup_docker.sh           # runtime only (default)
#   sudo bash setup_docker.sh --build   # runtime + image building tools
# ==============================================================================

# ------------------------------------------------------------------------------
# Parse arguments
# ------------------------------------------------------------------------------

INSTALL_BUILD_TOOLS=false
for arg in "$@"; do
  case "$arg" in
    --build) INSTALL_BUILD_TOOLS=true ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

# ------------------------------------------------------------------------------
# Pre-flight checks
# ------------------------------------------------------------------------------

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: This script must be run as root (or via sudo)." >&2
  exit 1
fi

# ------------------------------------------------------------------------------
# Remove any old/unofficial Docker packages
# ------------------------------------------------------------------------------

echo ">>> Removing any conflicting old Docker packages..."
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
  apt remove -y "$pkg" 2>/dev/null || true
done

# ------------------------------------------------------------------------------
# Install dependencies
# ------------------------------------------------------------------------------

echo ">>> Installing dependencies..."
apt update
apt install -y \
  ca-certificates \
  curl \
  gnupg \
  lsb-release

# ------------------------------------------------------------------------------
# Add Docker's official GPG key and repository
# ------------------------------------------------------------------------------

echo ">>> Adding Docker GPG key and repository..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | tee /etc/apt/sources.list.d/docker.list > /dev/null

# ------------------------------------------------------------------------------
# Install Docker Engine
# ------------------------------------------------------------------------------

echo ">>> Installing Docker Engine..."
apt update

PACKAGES="docker-ce docker-ce-cli containerd.io docker-compose-plugin"
if [ "$INSTALL_BUILD_TOOLS" = true ]; then
  echo "    (including build tools: docker-buildx-plugin)"
  PACKAGES="$PACKAGES docker-buildx-plugin"
fi

# shellcheck disable=SC2086
apt install -y $PACKAGES

# ------------------------------------------------------------------------------
# Enable and start Docker service
# ------------------------------------------------------------------------------

echo ">>> Enabling and starting Docker service..."
systemctl enable docker
systemctl start docker

# ------------------------------------------------------------------------------
# Add current user to the docker group (so they can run docker without sudo)
# ------------------------------------------------------------------------------

CURRENT_USER="${SUDO_USER:-$USER}"

if [ -n "$CURRENT_USER" ] && [ "$CURRENT_USER" != "root" ]; then
  echo ">>> Adding '$CURRENT_USER' to the docker group..."
  usermod -aG docker "$CURRENT_USER"
  ADDED_TO_GROUP=true
else
  ADDED_TO_GROUP=false
fi

# ------------------------------------------------------------------------------
# Verify installation
# ------------------------------------------------------------------------------

echo ">>> Verifying Docker installation..."
docker --version
docker compose version

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------

echo ""
echo "======================================================"
echo " Docker installation complete!"
echo "======================================================"
echo ""
echo "  Docker version  : $(docker --version)"
echo "  Compose version : $(docker compose version)"
echo "  Mode            : $([ "$INSTALL_BUILD_TOOLS" = true ] && echo "runtime + build tools" || echo "runtime only")"
echo ""

if [ "$ADDED_TO_GROUP" = true ]; then
  echo "  NOTE: '$CURRENT_USER' was added to the 'docker' group."
  echo "  Starting a fresh login shell as '$CURRENT_USER' to apply changes..."
  echo ""
  echo "  Test your install with:"
  echo "    docker run hello-world"
  echo ""
  echo "  To reinstall with image build support:"
  echo "    sudo bash setup_docker.sh --build"
  echo ""
  # Drop into a fresh login shell for the user so the new group is active immediately
  exec su - "$CURRENT_USER"
else
  echo "  Test your install with:"
  echo "    docker run hello-world"
  echo ""
  echo "  To reinstall with image build support:"
  echo "    sudo bash setup_docker.sh --build"
  echo ""
fi
