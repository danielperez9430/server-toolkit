#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Install Caddy with Cloudflare DNS plugin on Debian/Ubuntu
# ==============================================================================

echo ">>> Updating package lists and installing dependencies..."
sudo apt update
sudo apt install -y \
  debian-keyring \
  debian-archive-keyring \
  apt-transport-https \
  golang-go

echo ">>> Adding xcaddy repository and GPG key..."
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/xcaddy/gpg.key' \
  | sudo gpg --dearmor -o /usr/share/keyrings/caddy-xcaddy-archive-keyring.gpg

curl -1sLf 'https://dl.cloudsmith.io/public/caddy/xcaddy/debian.deb.txt' \
  | sudo tee /etc/apt/sources.list.d/caddy-xcaddy.list

sudo apt update
sudo apt install -y xcaddy

echo ">>> Building Caddy with Cloudflare DNS provider plugin..."
xcaddy build --with github.com/caddy-dns/cloudflare

sudo mv caddy /usr/local/bin/caddy
sudo chmod +x /usr/local/bin/caddy

echo ">>> Creating caddy system user and group..."
sudo groupadd --system caddy || true
sudo useradd --system \
  --gid caddy \
  --create-home \
  --home-dir /var/lib/caddy \
  --shell /usr/sbin/nologin \
  --comment "Caddy web server" \
  caddy || true

echo ">>> Setting up Caddy directories and permissions..."

# Config directory
sudo mkdir -p /etc/caddy
sudo chown -R caddy:caddy /etc/caddy

# Create an empty Caddyfile only if one doesn't already exist
if [ ! -f /etc/caddy/Caddyfile ]; then
  sudo touch /etc/caddy/Caddyfile
fi
sudo chmod 644 /etc/caddy/Caddyfile

# Data directory (used by Caddy for TLS certs, etc.)
sudo mkdir -p /var/lib/caddy
sudo chown -R caddy:caddy /var/lib/caddy
sudo chmod 750 /var/lib/caddy  # Tightened: only caddy user/group needs access

# Log directory
sudo mkdir -p /var/log/caddy
sudo chown -R caddy:caddy /var/log/caddy
sudo chmod 750 /var/log/caddy  # Tightened: only caddy user/group needs access

echo ">>> Writing systemd service file..."
sudo tee /etc/systemd/system/caddy.service > /dev/null << 'EOF'
[Unit]
Description=Caddy Web Server
Documentation=https://caddyserver.com/docs/
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=exec
User=caddy
Group=caddy
ExecStart=/usr/local/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

echo ">>> Enabling Caddy service (not starting)..."
sudo systemctl daemon-reload
sudo systemctl enable caddy

echo ""
echo "======================================================"
echo " Caddy installation complete!"
echo "======================================================"
echo ""
echo " Next steps:"
echo "   1. Edit your Caddyfile:  sudo nano /etc/caddy/Caddyfile"
echo "   2. Start Caddy:          sudo systemctl start caddy"
echo "   3. Check status:         sudo systemctl status caddy"
echo "   4. View logs:            sudo journalctl -u caddy -f"
echo ""
echo " For Cloudflare DNS challenge, add your API token to"
echo " the Caddyfile under the tls block, e.g.:"
echo ""
echo "   tls {"
echo "     dns cloudflare <YOUR_CF_API_TOKEN>"
echo "   }"
echo ""
