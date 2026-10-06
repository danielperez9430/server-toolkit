#!/bin/bash

# ============================================================
# VPS Backup — Backblaze uninstall
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; }

if [ "$(id -u)" -ne 0 ]; then
    err "Must run as root: sudo bash uninstall.sh"
    exit 1
fi

echo ""
echo "============================================"
echo " Uninstall VPS Backup"
echo "============================================"
echo ""

# -- Remove cron job --
if crontab -l 2>/dev/null | grep -q "/usr/local/bin/backup.sh" 2>/dev/null; then
    crontab -l 2>/dev/null | grep -v "/usr/local/bin/backup.sh" | crontab - 2>/dev/null
    log "Cron job removed."
else
    warn "No cron job found."
fi

# -- Remove backup script --
if [ -f /usr/local/bin/backup.sh ]; then
    rm -f /usr/local/bin/backup.sh
    log "Removed /usr/local/bin/backup.sh"
else
    warn "/usr/local/bin/backup.sh not found."
fi

# -- Remove local backup directory --
read -rp "Delete /var/backups/vps? [y/N] " ANS
echo ""
case "$ANS" in
    [Yy]|[Yy][Ee][Ss]) rm -rf /var/backups/vps; log "Deleted /var/backups/vps" ;;
    *) warn "Skipped /var/backups/vps" ;;
esac

# -- Remove backup log --
read -rp "Delete /var/log/backup.log? [y/N] " ANS
echo ""
case "$ANS" in
    [Yy]|[Yy][Ee][Ss]) rm -f /var/log/backup.log; log "Deleted /var/log/backup.log" ;;
    *) warn "Skipped /var/log/backup.log" ;;
esac

# -- Remove rclone config --
read -rp "Remove rclone remote 'b2-vps'? [y/N] " ANS
echo ""
case "$ANS" in
    [Yy]|[Yy][Ee][Ss])
        if rclone config delete b2-vps 2>/dev/null; then
            log "rclone remote 'b2-vps' removed."
        else
            warn "rclone remote not found or already removed."
        fi
        ;;
    *) warn "Skipped rclone config." ;;
esac

echo ""
echo "Uninstall complete."
echo ""
echo "Note: this does NOT delete the Backblaze bucket or its files."
echo "Log in to https://www.backblaze.com to remove them manually."
echo ""
