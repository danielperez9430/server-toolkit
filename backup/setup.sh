#!/bin/bash
set -euo pipefail

# ============================================================
# VPS Backup — Backblaze
# one-command setup
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
fail() { echo -e "${RED}[✗]${NC} $*"; exit 1; }

echo ""
echo "============================================"
echo " VPS Backup — Backblaze Setup"
echo "============================================"
echo ""

# -- check root & detect real user --
if [ "$(id -u)" -ne 0 ]; then
    fail "This script must be run as root. Use: sudo bash setup.sh"
fi

REAL_USER="${SUDO_USER:-root}"
REAL_HOME=$(eval echo "~$REAL_USER")

# Run rclone as the real user (not root) so it finds the right config
rclone() {
    if [ "$REAL_USER" != "root" ]; then
        command sudo -u "$REAL_USER" HOME="$REAL_HOME" rclone "$@"
    else
        command rclone "$@"
    fi
}

# -- step 0: ask for bucket name --
DEFAULT_BUCKET="server-backups"
echo "----------------------------------------------------"
echo " Backblaze B2 bucket name"
echo "----------------------------------------------------"
echo ""
echo "  Bucket names are globally unique (like S3)."
echo "  Create the bucket at https://www.backblaze.com first."
echo ""
read -rp "  Bucket name [$DEFAULT_BUCKET]: " BUCKET_INPUT
BUCKET="${BUCKET_INPUT:-$DEFAULT_BUCKET}"

# Ask for rclone remote name
DEFAULT_REMOTE="b2-vps"
read -rp "  rclone remote name [$DEFAULT_REMOTE]: " REMOTE_INPUT
REMOTE="${REMOTE_INPUT:-$DEFAULT_REMOTE}"

echo ""
log "Using: rclone remote '$REMOTE' → bucket '$BUCKET'"

# -- step 1: install dependencies --
if command -v rclone &>/dev/null; then
    log "rclone already installed: $(rclone version --check 2>&1 | head -1)"
else
    log "Installing rclone..."
    curl -fsSL https://rclone.org/install.sh | bash
    log "rclone installed."
fi

if command -v pv &>/dev/null; then
    log "pv already installed (progress bar)."
else
    log "Installing pv for progress bar..."
    if command -v apt &>/dev/null; then
        apt install -y pv
    elif command -v yum &>/dev/null; then
        yum install -y pv
    elif command -v apk &>/dev/null; then
        apk add pv
    else
        warn "Could not install pv — backups will run without progress bar."
    fi
fi

# -- step 2: configure rclone remote --
if rclone listremotes 2>/dev/null | grep -q "^$REMOTE:$"; then
    warn "rclone remote '$REMOTE' already exists. Skipping config."
    warn "To reconfigure: rclone config delete $REMOTE && rclone config"
else
    echo ""
    echo "----------------------------------------------------"
    echo " CONFIGURING rclone for Backblaze B2"
    echo "----------------------------------------------------"
    echo ""
    echo "You will need:"
    echo "  1. keyID         (from Backblaze Application Keys)"
    echo "  2. applicationKey (shown only once when creating the key)"
    echo ""
    echo "Pressing Enter now will open the interactive config..."
    read -rp "Press Enter to continue..."

    echo ""
    echo "Follow these prompts:"
    echo "  n) New remote"
    echo "  name> $REMOTE"
    echo "  Storage> b2   (type 'b2', then Enter for Backblaze B2)"
    echo "  Account>      (paste keyID)"
    echo "  Key>          (paste applicationKey)"
    echo "  Hard delete>  (leave blank for default: No)"
    echo "  Advanced?     n"
    echo "  Keep?         y"
    echo "  q) Quit config"
    echo ""

    rclone config

    if ! rclone listremotes 2>/dev/null | grep -q "^$REMOTE:$"; then
        fail "Remote '$REMOTE' not found after config. Try again."
    fi

    log "Remote '$REMOTE' configured."
fi

# -- step 3: verify connection --
echo ""
log "Verifying connection to bucket '$BUCKET'..."
echo ""
echo "  A write-only key cannot list files, so rclone lsd will fail."
echo "  Testing with a small upload instead..."
echo ""

if echo "rclone-test-$(date +%s)" | rclone rcat "$REMOTE:$BUCKET/.backup-test" 2>/dev/null; then
    log "Bucket '$BUCKET' is reachable — upload succeeded."
    warn "Test file '.backup-test' was left in the bucket (can't delete with write-only key)."
    warn "It will expire with your lifecycle rule. You can safely ignore it."
else
    fail "Cannot upload to bucket '$BUCKET'. Check the key permissions and bucket name."
fi

# -- step 4: deploy backup script --
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ ! -f "$SCRIPT_DIR/backup.sh" ]; then
    fail "backup.sh not found next to setup.sh. Keep them together."
fi

# Write the bucket and remote names into the deployed script.
# Insert RCLONE_CONFIG export AFTER the shebang line (so shebang stays on line 1
# and the kernel actually honors it). Then replace the B2_BUCKET/B2_REMOTE defaults.
sed \
    -e "1a\\
export RCLONE_CONFIG=\"$REAL_HOME/.config/rclone/rclone.conf\"" \
    -e "s/\${B2_BUCKET:-[^}]*}/\${B2_BUCKET:-$BUCKET}/" \
    -e "s/\${B2_REMOTE:-[^}]*}/\${B2_REMOTE:-$REMOTE}/" \
    "$SCRIPT_DIR/backup.sh" > /usr/local/bin/backup.sh
chmod 755 /usr/local/bin/backup.sh
log "backup.sh deployed to /usr/local/bin/backup.sh"

# -- step 4.5: healthchecks.io (optional) --
echo ""
echo "----------------------------------------------------"
echo " Healthchecks.io (optional monitoring)"
echo "----------------------------------------------------"
echo ""
echo "  healthchecks.io watches your cron jobs. If a backup"
echo "  doesn't run on time, it alerts you (email, Telegram,"
echo "  Discord...). Free tier = 20 checks."
echo ""
read -rp "  Configure healthchecks.io now? [y/N] " HC_ANSWER
echo ""

HEALTHCHECK_URL=""
case "$HC_ANSWER" in
    [Yy]|[Yy][Ee][Ss])
        while true; do
            read -rp "  Paste your Ping URL: " HC_URL
            # Validate: must start with https://hc-ping.com/
            if echo "$HC_URL" | grep -qE '^https://hc-ping\.com/[a-f0-9-]{20,}'; then
                HEALTHCHECK_URL="$HC_URL"
                log "Healthchecks URL accepted."
                break
            else
                warn "Invalid URL. Expected: https://hc-ping.com/<uuid>"
                echo "  Example: https://hc-ping.com/a1b2c3d4-e5f6-7890-abcd-ef1234567890"
                echo ""
            fi
        done

        # Inject the URL into the deployed script
        sed -i "s|HEALTHCHECK_URL=\"\"|HEALTHCHECK_URL=\"$HEALTHCHECK_URL\"|" /usr/local/bin/backup.sh
        log "Injected HEALTHCHECK_URL into /usr/local/bin/backup.sh"
        ;;
    *)
        warn "Skipped. You can set it later in /usr/local/bin/backup.sh"
        ;;
esac

# -- step 5: add cron --
CRON_LINE="17 3 * * 0 /usr/local/bin/backup.sh >> /var/log/backup.log 2>&1"
CRON_TMP=$(mktemp)
crontab -l 2>/dev/null > "$CRON_TMP" || true

# Ensure cron uses bash so the script's bash features (pipefail, etc.) work
if ! grep -q "^SHELL=" "$CRON_TMP"; then
    sed -i "1iSHELL=/bin/bash" "$CRON_TMP"
fi

if grep -qF "/usr/local/bin/backup.sh" "$CRON_TMP"; then
    warn "Cron job already exists. Skipping."
else
    echo "$CRON_LINE" >> "$CRON_TMP"
    crontab "$CRON_TMP"
    log "Cron added: Sunday at 03:17 AM"
fi

rm "$CRON_TMP"

# -- step 6: first backup --
echo ""
echo "============================================"
echo " RUNNING FIRST BACKUP"
echo "============================================"
echo ""

if /usr/local/bin/backup.sh; then
    echo ""
    log "First backup completed successfully."
else
    warn "First backup failed. Check /var/log/backup.log"
fi

# -- step 7: summary --
echo ""
echo "============================================"
echo " SETUP COMPLETE"
echo "============================================"
echo ""
echo "  Script:   /usr/local/bin/backup.sh"
echo "  Log:      /var/log/backup.log"
echo "  Bucket:   $BUCKET"
echo "  Cadence:  Sunday 03:17 AM (weekly)"
echo "  Retention: 30 days (Backblaze lifecycle rule)"
echo ""
echo "  Manual run:  /usr/local/bin/backup.sh"
echo "  View log:    tail -f /var/log/backup.log"
echo "  Cron check:  crontab -l"
echo ""

if [ -n "$HEALTHCHECK_URL" ]; then
    echo "  Healthchecks: $HEALTHCHECK_URL"
else
    echo "  Optional: set HEALTHCHECK_URL in /usr/local/bin/backup.sh"
    echo "            https://healthchecks.io (free tier)"
fi
echo ""
