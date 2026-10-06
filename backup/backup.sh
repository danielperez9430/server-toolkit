#!/bin/bash
# Uses arrays, PIPESTATUS and process substitution: bash only. setup.sh puts
# SHELL=/bin/bash in the crontab, and the shebang covers a direct run.
set -euo pipefail

# ============================================================
# VPS Backup — Backblaze
# adaptive local vs stream, zero-local on low disk (dumps excepted),
# live databases dumped instead of copied
# ============================================================

# --dry-run: find the databases, dump them to a temp dir and show what would be
# archived and left out — no archive, no upload, no healthchecks ping.
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

TIMESTAMP=$(date +%Y-%m-%d_%H%M%S)
BUCKET="${B2_BUCKET:-server-backups}"
REMOTE="${B2_REMOTE:-b2-vps}:$BUCKET"
LOCAL_DIR="/var/backups/vps"
HEALTHCHECK_URL=""   # optional — fill in uuid from healthchecks.io

# What to back up and what to leave out. Any of these, and the four settings
# above, can be overridden in /etc/backup.conf (a bash file), e.g.:
#   SOURCES=(/var/www /etc/caddy/Caddyfile /srv/app)
#   EXTRA_EXCLUDES=(/var/www/ghost/content/logs)
#   DUMP_ALL_DATABASES=1
SOURCES=(/var/www /etc/caddy/Caddyfile)
EXTRA_EXCLUDES=()
# Databases in Docker whose data lives OUTSIDE SOURCES aren't in this backup
# at all. 0 just says so in the log; 1 dumps them too.
DUMP_ALL_DATABASES=0
DUMP_TIMEOUT=2h

if [ "$(id -u)" -ne 0 ]; then
    echo "Must run as root: it reads every app's files and talks to Docker." >&2
    exit 1
fi

CONF=/etc/backup.conf
if [ -e "$CONF" ]; then
    # It's sourced as root, so it must be as protected as this script.
    if [ "$(stat -c '%u' "$CONF")" != 0 ] || [ $(( 0$(stat -c '%a' "$CONF") & 022 )) -ne 0 ]; then
        echo "Refusing $CONF: it must be owned by root and not group/world-writable." >&2
        exit 1
    fi
    # shellcheck source=/dev/null
    . "$CONF"
fi

BACKUP_NAME="backup-$TIMESTAMP.tar.gz"
LOCAL_PATH="$LOCAL_DIR/$BACKUP_NAME"
DUMP_DIR="$LOCAL_DIR/dumps-$TIMESTAMP"
TAR_ERR=""
# Set when a database could not be dumped: the rest is still uploaded, and the
# run ends as failed so healthchecks says why.
FAILED=0
# This run's own log lines, sent along with the healthchecks pings so an alert
# says why — tar's and the dump tools' errors used to go to /dev/null.
RUN_LOG=$(mktemp /tmp/backup-run.XXXXXX)

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$RUN_LOG"
}

# Append a captured stderr file to the log, indented, minus tar's harmless note.
log_stderr() {
    [ -s "$1" ] && grep -v -E "Removing leading .?/" "$1" | sed 's/^/    /' | tee -a "$RUN_LOG"
    rm -f "$1"
    return 0
}

# pv only on a terminal: under cron its progress lines would fill the log.
maybe_pv() {
    if [ -t 2 ] && command -v pv &>/dev/null; then
        if [ -n "${1:-}" ]; then pv -s "$1"; else pv; fi
    else
        cat
    fi
}

ping_hc() {  # ping_hc [suffix] [body]
    [ -n "$HEALTHCHECK_URL" ] && [ "$DRY_RUN" = 0 ] || return 0
    curl -fsS -m 10 --retry 3 -o /dev/null --data-raw "${2:-}" "$HEALTHCHECK_URL${1:-}" || true
}

# ---- Cleanup trap: partial archive, dumps, temp files, failure ping ----
on_exit() {
    local rc=$?
    if [ -f "$LOCAL_PATH" ] && [ "$rc" -ne 0 ]; then
        log "Cleaning up incomplete local archive..."
        rm -f "$LOCAL_PATH"
    fi
    rm -rf "$DUMP_DIR"
    [ -n "$TAR_ERR" ] && rm -f "$TAR_ERR"
    if [ "$rc" -ne 0 ]; then
        log "Backup FAILED (exit $rc)"
        # healthchecks.io alerts once, when a check goes down. Pinging /fail
        # makes that alert immediate and puts the reason in it.
        ping_hc /fail "$(tail -c 9000 "$RUN_LOG")"
    fi
    rm -f "$RUN_LOG"
}
trap on_exit EXIT

# One run at a time: a hung dump or a slow upload must not meet next week's.
exec 9>/run/lock/backup.lock
flock -n 9 || { log "Another backup is still running; not starting a second one."; exit 1; }

# tar exits 1 when a file changed while it was read — it's still in the
# archive, as a warning, not a failure. 2 is a real error. Takes the
# PIPESTATUS of the pipeline that ran tar first.
check_pipeline() {  # check_pipeline <what> <status...>
    local what=$1 tar_rc=$2; shift 2
    if [ "$tar_rc" -gt 1 ]; then
        log "tar failed (exit $tar_rc) while $what"
        return 1
    fi
    for rc in "$@"; do
        if [ "$rc" -ne 0 ]; then
            log "pipeline failed (exit $rc) while $what"
            return 1
        fi
    done
    [ "$tar_rc" -eq 1 ] && log "Note: some files changed while being read; archived as they were."
    return 0
}

# Is this path inside one of the SOURCES?
in_sources() {
    local p=$1 s
    for s in "${SOURCES[@]}"; do
        case "$p/" in "${s%/}/"*) return 0 ;; esac
    done
    return 1
}

ping_hc /start

# ---- Check rclone is available ----
if ! command -v rclone &>/dev/null; then
    log "FATAL: rclone not found. Install it: curl https://rclone.org/install.sh | sudo bash"
    exit 1
fi

# ---- Only the SOURCES that exist: a server without Caddy shouldn't fail ----
present=()
for s in "${SOURCES[@]}"; do
    if [ -e "$s" ]; then present+=("$s"); else log "Skipping $s: not found"; fi
done
[ ${#present[@]} -gt 0 ] || { log "None of the SOURCES exist: ${SOURCES[*]}"; exit 1; }
SOURCES=("${present[@]}")

EXCLUDES=(
    --exclude='node_modules'
    --exclude='.cache'
    --exclude='.npm'
    --exclude='__pycache__'
    --exclude='*.pyc'
    --exclude='.next'
)
for x in "${EXTRA_EXCLUDES[@]}"; do EXCLUDES+=("--exclude=$x"); done
# Everything after this is a literal path: without it, a directory named
# "cache[1]" would be read as a pattern and not excluded.
EXCLUDES+=(--no-wildcards)

# ============================================================
# Live databases
# ------------------------------------------------------------
# A database's files can't be copied while it runs: when it writes mid-read,
# tar stops with "file changed as we read it", and even a copy that gets
# through can be inconsistent. So databases are dumped consistently into
# DUMP_DIR, which goes in the archive, and their raw files are left out.
# Nothing here names an app: each is found by what it is, not where it is.
# A dump that fails is logged, its raw files stay in the archive as a last
# resort, and the run ends as failed.
# ============================================================
mkdir -p "$DUMP_DIR"
log "Looking for live databases under: ${SOURCES[*]}"

dump_container() {  # dump_container <name> <engine> <out>
    local name=$1 engine=$2 out=$3 err rc
    err=$(mktemp)
    set +e
    if [ "$engine" = mysql ]; then
        # The password comes from the container's own env (or its _FILE
        # variant), through MYSQL_PWD so it never shows in a process list.
        timeout "$DUMP_TIMEOUT" docker exec "$name" sh -c '
            pw="${MYSQL_ROOT_PASSWORD:-${MARIADB_ROOT_PASSWORD:-}}"
            f="${MYSQL_ROOT_PASSWORD_FILE:-${MARIADB_ROOT_PASSWORD_FILE:-}}"
            [ -z "$pw" ] && [ -n "$f" ] && [ -r "$f" ] && pw=$(cat "$f")
            dump=$(command -v mysqldump || command -v mariadb-dump) || { echo "no mysqldump or mariadb-dump in the image" >&2; exit 127; }
            MYSQL_PWD="$pw" exec "$dump" -uroot --single-transaction --routines --triggers --events --hex-blob --all-databases' \
            2>"$err" | gzip > "$out"
    else
        timeout "$DUMP_TIMEOUT" docker exec "$name" sh -c '
            PGPASSWORD="${POSTGRES_PASSWORD:-${POSTGRESQL_PASSWORD:-}}" \
            exec pg_dumpall -U "${POSTGRES_USER:-${POSTGRESQL_USERNAME:-postgres}}"' \
            2>"$err" | gzip > "$out"
    fi
    rc=${PIPESTATUS[0]}
    set -e
    grep -v -i "deprecated" "$err" > "$err.f" || true; mv "$err.f" "$err"
    log_stderr "$err"
    return "$rc"
}

# -- Databases in Docker: MySQL/MariaDB and PostgreSQL, found by image. --
if command -v docker &>/dev/null; then
    if ! containers=$(docker ps --format '{{.Names}} {{.Image}}' 2>&1); then
        log "WARNING: docker ps failed, no container database will be dumped: $containers"
        FAILED=1
        containers=""
    fi
    while read -r name image; do
        [ -n "$name" ] || continue
        case "$image" in
            *mysql*|*mariadb*|*percona*) engine=mysql; datadir=/var/lib/mysql ;;
            *postgres*|*postgis*|*timescale*) engine=postgres; datadir=/var/lib/postgresql ;;
            *mongo*|*couchdb*|*cassandra*|*elasticsearch*|*opensearch*)
                log "  $name ($image): database engine not supported; if its data is in SOURCES it's copied live"
                continue ;;
            *) continue ;;
        esac
        # Where its data really is, from the bind mount on the data dir
        # (exact dir or below it: /var/lib/mysql-files is not /var/lib/mysql).
        src=$(docker inspect "$name" --format \
            '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}|{{.Destination}}{{"\n"}}{{end}}{{end}}' 2>/dev/null \
            | awk -F'|' -v d="$datadir" '$2 == d || index($2, d "/") == 1 {print $1; exit}') || true
        inside=0
        [ -n "$src" ] && in_sources "$src" && inside=1
        if [ "$inside" = 0 ] && [ "$DUMP_ALL_DATABASES" != 1 ]; then
            log "  $name: $engine with data outside SOURCES — NOT in this backup (DUMP_ALL_DATABASES=1 adds it)"
            continue
        fi
        if dump_container "$name" "$engine" "$DUMP_DIR/$name.sql.gz"; then
            [ "$inside" = 1 ] && EXCLUDES+=("--exclude=$src")
            log "  $name: $engine${src:+ in $src}, dumped"
        else
            rm -f "$DUMP_DIR/$name.sql.gz"
            FAILED=1
            log "  $name: $engine dump FAILED; ${src:+its raw files in $src stay in the archive}"
        fi
    done <<< "$containers"
fi

# -- SQLite: any database file inside SOURCES, recognised by its header and
#    copied with SQLite's online backup API, which is safe while it's written.
#    Excluded paths aren't searched, so a deliberately excluded .db isn't
#    copied to disk first. --
prune=(\( -name node_modules -o -name .git -o -name .cache)
for x in "${EXTRA_EXCLUDES[@]}"; do prune+=(-o -path "$x"); done
prune+=(\) -prune)
while IFS= read -r -d '' f; do
    [ "$(head -c 15 "$f" 2>/dev/null)" = "SQLite format 3" ] || continue
    out="$DUMP_DIR/sqlite${f//\//_}"
    err=$(mktemp)
    if timeout "$DUMP_TIMEOUT" python3 - "$f" "$out" 2>"$err" <<'PY'
import sqlite3, sys
src = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
dst = sqlite3.connect(sys.argv[2])
src.backup(dst)
dst.close(); src.close()
PY
    then
        for suffix in "" -wal -shm -journal; do EXCLUDES+=("--exclude=$f$suffix"); done
        log "  $f: sqlite, copied"
    else
        rm -f "$out"
        FAILED=1
        log "  $f: sqlite copy FAILED; the raw file stays in the archive"
    fi
    log_stderr "$err"
done < <(find "${SOURCES[@]}" "${prune[@]}" -o -type f \
             \( -name '*.sqlite' -o -name '*.sqlite3' -o -name '*.db' -o -name '*.db3' -o -name '*.sq3' -o -name '*.s3db' \) \
             -size +0 -print0 2>/dev/null || true)

if [ -n "$(ls -A "$DUMP_DIR")" ]; then
    log "Dumps: $(du -sh "$DUMP_DIR" | awk '{print $1}')"
    SOURCES+=("$DUMP_DIR")
else
    log "  none found"
fi

# ---- Estimate uncompressed data size (KB) ----
# du fails if a file vanishes while it counts (temp uploads); an estimate
# doesn't need to be exact, so that must not stop the backup.
log "Estimating backup size..."
# --no-wildcards is tar's; du would reject it and estimate nothing.
DU_EXCLUDES=()
for x in "${EXCLUDES[@]}"; do [ "$x" = --no-wildcards ] || DU_EXCLUDES+=("$x"); done
ESTIMATED_KB=$(du -skc "${DU_EXCLUDES[@]}" "${SOURCES[@]}" 2>/dev/null | tail -1 | awk '{print $1}') || true
ESTIMATED_KB=${ESTIMATED_KB:-0}
ESTIMATED_MB=$((ESTIMATED_KB / 1024))

# ---- Available disk space in backup directory (KB) ----
mkdir -p "$LOCAL_DIR"
AVAILABLE_KB=$(df --output=avail "$LOCAL_DIR" 2>/dev/null | tail -1 | tr -d ' ') || true
AVAILABLE_KB=${AVAILABLE_KB:-0}

log "Estimated data: ${ESTIMATED_MB}MB | Available space: $((AVAILABLE_KB / 1024))MB"

if [ "$DRY_RUN" = 1 ]; then
    log "Dry run. Would archive: ${SOURCES[*]}"
    printf '    %s\n' "${EXCLUDES[@]}"
    ls -la "$DUMP_DIR"
    exit "$FAILED"
fi

TAR_ERR=$(mktemp /tmp/backup-tar.XXXXXX)

# ---- Decision: local archive vs direct stream ----
if [ "$AVAILABLE_KB" -gt "$((ESTIMATED_KB * 2))" ]; then
    # ----- PATH A: Enough space — archive locally, upload, delete -----
    log "Disk space OK. Creating local archive (estimated ${ESTIMATED_MB}MB)..."

    # tar → pv (progress) → file
    set +e
    tar -czf - "${EXCLUDES[@]}" "${SOURCES[@]}" 2>"$TAR_ERR" \
        | maybe_pv "$((ESTIMATED_KB * 1024))" \
        > "$LOCAL_PATH"
    st=("${PIPESTATUS[@]}")
    set -e
    log_stderr "$TAR_ERR"
    check_pipeline "creating the archive" "${st[@]}"

    ACTUAL_MB=$(du -m "$LOCAL_PATH" | awk '{print $1}')
    log "Archive: ${ACTUAL_MB}MB. Uploading to B2..."

    # Use rcat (stdin) instead of copy — copy does HEAD check which fails on write-only keys
    maybe_pv "" < "$LOCAL_PATH" | rclone rcat "$REMOTE/$BACKUP_NAME" || {
        log "Upload failed."
        exit 1
    }

    log "Upload complete. Removing local archive..."
    rm "$LOCAL_PATH"

else
    # ----- PATH B: Low on space — stream directly to B2, zero local bytes -----
    log "Low disk space. Streaming directly to B2 (no local file)..."

    set +e
    tar -czf - "${EXCLUDES[@]}" "${SOURCES[@]}" 2>"$TAR_ERR" \
        | rclone rcat "$REMOTE/$BACKUP_NAME"
    st=("${PIPESTATUS[@]}")
    set -e
    log_stderr "$TAR_ERR"
    check_pipeline "streaming to B2" "${st[@]}"

    log "Stream upload complete."
fi

if [ "$FAILED" = 1 ]; then
    log "Uploaded $BACKUP_NAME, but some databases could not be dumped (see above)."
    exit 1
fi

ping_hc "" "$(tail -c 9000 "$RUN_LOG")"
log "Backup finished successfully: $BACKUP_NAME"
