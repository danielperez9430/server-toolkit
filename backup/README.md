# VPS Backup — Backblaze

Weekly encrypted backup to Backblaze B2. VPS holds a **write-only key** — it can upload but never list, read, or delete files in the bucket. Retention is enforced server-side by Backblaze lifecycle rules, out of the attacker's reach.

---

## Security Model

| Concern | Protection |
|---|---|
| Malware on VPS deletes backups | Key is write-only — `rclone delete` fails |
| Malware overwrites backups | Unique timestamped filenames; key can't list to find old files |
| Malware corrupts the script | Healthcheck monitoring (healthchecks.io optional ping) |
| VPS destroyed entirely | B2 bucket is independent; nothing stored on VPS after upload |
| Backblaze account compromise | Enable 2FA on the Backblaze account |

### Retention

Each backup lives **30 days** in Backblaze, then auto-deleted by lifecycle rule.

| Cadence | Copies kept |
|---|---|
| Weekly (Sunday 03:17) | 4 copies rotating |

To restore, use a **separate full-access key** you store offline. Never put that key on the VPS.

---

## What Gets Backed Up

```
/var/www                  # Web apps, uploads, assets
/etc/caddy/Caddyfile      # Reverse proxy config
/var/backups/vps/dumps-*  # Consistent dumps of the live databases (see below)
```

A path that doesn't exist is skipped with a note in the log, so a server
without Caddy still backs up the rest.

Excluded (waste of space, reproducible):
```
node_modules  .cache  .npm  __pycache__  *.pyc  .next
```

`vendor/` is **not** excluded: in PHP apps it isn't always reinstallable.

### Live databases

A database's files can't be copied while it runs: when it writes mid-read, tar
stops with "file changed as we read it", and even a copy that gets through can
be inconsistent. So before the archive is built, the script finds databases by
**what they are, not where they are**, and dumps them:

| Found as | How it's found | Dumped with | In the archive as |
|---|---|---|---|
| MySQL / MariaDB / Percona in Docker | image name; data dir bind-mounted inside the backed-up paths | `mysqldump --single-transaction --all-databases` | `dumps-*/<container>.sql.gz` |
| PostgreSQL / PostGIS / TimescaleDB in Docker | same | `pg_dumpall` | `dumps-*/<container>.sql.gz` |
| SQLite | any `*.sqlite`, `*.sqlite3`, `*.db`, `*.db3`, `*.sq3`, `*.s3db` inside the backed-up paths whose header says SQLite | SQLite's online backup API | `dumps-*/sqlite_<path_with_underscores>` |

Their raw files are left out of the archive. Credentials come from the
container's own environment (`MYSQL_ROOT_PASSWORD`, `MARIADB_ROOT_PASSWORD`, their
`_FILE` variants, `POSTGRES_USER`/`POSTGRES_PASSWORD`), and never show up in a
process list.

- A Docker database whose data lives **outside** the backed-up paths (for
  example in a named volume) is not in this backup, and the log says so. Set
  `DUMP_ALL_DATABASES=1` to dump those too.
- MongoDB, CouchDB, Elasticsearch and the like are recognised but not dumped:
  the log says so, and their files are copied as they are.
- If a dump fails, the error goes to the log, the database's raw files stay in
  the archive as a last resort, the rest is uploaded, and the run ends as
  failed so healthchecks tells you why.
- Any other file that changes while tar reads it is archived as it was, with a
  note in the log: a warning, not a failed backup.

### Per-server settings: `/etc/backup.conf`

Optional. A bash file sourced by the script, which must be owned by root and
not writable by anyone else (the script refuses it otherwise). Example:

```bash
SOURCES=(/var/www /etc/caddy/Caddyfile /srv/app)   # what to back up
EXTRA_EXCLUDES=(/var/www/blog/content/logs)        # more paths to leave out
DUMP_ALL_DATABASES=1                               # also dump DBs outside SOURCES
DUMP_TIMEOUT=2h                                    # per database
HEALTHCHECK_URL="https://hc-ping.com/<uuid>"       # instead of editing the script
```

### Check before it runs

```bash
sudo /usr/local/bin/backup.sh --dry-run
```

Finds and dumps the databases into a temporary folder, then lists what would be
archived and every exclusion — no archive, no upload, no healthchecks ping.

---

## Dependencies

The setup script installs these automatically, but if you're running the backup script manually:

| Package | Purpose | Install |
|---|---|---|
| `rclone` | Upload to Backblaze B2 | `sudo apt install rclone` |
| `pv` | Progress bar during tar & upload | `sudo apt install pv` |

Both are optional — the backup script falls back to `cat` if `pv` is missing.

---

## Setup (VPS)

### 1. Create the Backblaze B2 bucket

1. Go to https://www.backblaze.com → **Buckets** → **Create a Bucket**
2. Name: pick any unique name (bucket names are global, like S3). Example: `server-backups`
3. Encryption:
   - **Enable** default server-side encryption (AES-256, free, no perf hit)
   - Backblaze will warn: *"Encrypted files are excluded from Snapshots"*
   - **This is fine** — we use Lifecycle rules to expire old backups, not Snapshots. Lifecycle works normally on encrypted files. Snapshots are a separate optional feature we don't rely on.
4. After creation → **Lifecycle Settings**:
   - Versioning: **Keep all versions of the file** (we use unique filenames — no overwrites ever)
   - **Add Custom Lifecycle Rule**:
     | Field | Value |
     |---|---|
     | File Name Prefix | `backup-` |
     | Days From Uploading To Hiding | `30` |
     | Days From Hiding To Deleting | `1` |
   - This means: each backup is downloadable for 30 days, then deleted on day 31.
   - With weekly cadence, you'll always have 4 copies in rotation.

### 2. Create the write-only application key

1. **Application Keys** → **Add a New Application Key**
2. Fill the form:
   | Field | Value |
   |---|---|
   | Name of Key | `vps-write-only` |
   | Allow access to Bucket(s) | your bucket |
   | Type of Access | **Write Only** |
   | Allow List All Bucket Names | leave blank |
   | File name prefix | leave blank |
   | Duration (seconds) | leave blank (no expiry) |
3. Click **Create Key**
4. Copy `keyID` and `applicationKey` — you see the key **once**

> The key's capabilities will be `listBuckets, listFiles, writeFiles`. It can see filenames but cannot download content or delete files.

### 3. Run the setup script on the VPS

```bash
# Copy the files to the VPS
scp backup/setup.sh backup/backup.sh backup/uninstall.sh user@vps:/tmp/

# SSH in and run setup
ssh user@vps
sudo bash /tmp/setup.sh
```

The installer asks:
- **Bucket name** — the one you created in step 1
- **rclone remote name** — defaults to `b2-vps`

Then it:
- Installs `rclone` if missing
- Walks you through `rclone config` (you'll paste the B2 key)
- Writes the bucket name into `/usr/local/bin/backup.sh`
- Adds the weekly cron job
- Runs and verifies the first backup

You'll need the Backblaze `keyID` and `applicationKey` from step 2.

> ⚠️ With a write-only key, `rclone ls` and `rclone lsd` will fail — that's expected. The setup script verifies the connection by doing a test upload instead.

---

## Restoring a Backup

Use a **separate full-access Backblaze key** (or the master key). Never put this on the VPS.

```bash
# From any machine with rclone and a full-access key
rclone ls b2-full:server-backups/

# Pull the one you need
rclone copy b2-full:server-backups/backup-2026-06-01_031701.tar.gz .

# Extract to inspect
tar -xzf backup-2026-06-01_031701.tar.gz -C /tmp/restore

# Restore live
sudo tar -xzf backup-2026-06-01_031701.tar.gz -C /
```

The databases come back from their dumps, not from files:

```bash
# MySQL / MariaDB, into the running container
zcat /tmp/restore/var/backups/vps/dumps-*/<container>.sql.gz \
  | docker exec -i <container> sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -uroot'

# PostgreSQL, into the running container
zcat /tmp/restore/var/backups/vps/dumps-*/<container>.sql.gz \
  | docker exec -i <container> psql -U postgres

# SQLite, with its app stopped: the file name is the original path, / → _
cp /tmp/restore/var/backups/vps/dumps-*/sqlite_var_www_app_data_db.sqlite /var/www/app/data/db.sqlite
```

`--all-databases` includes MySQL's own `mysql` schema: restoring into a
different major version may need care with it.

---

## Healthchecks.io (Monitoring)

[healthchecks.io](https://healthchecks.io) monitors your cron jobs. When the backup finishes, it pings healthchecks. If the ping **doesn't** arrive on schedule, you get an alert. No more silently failing backups.

### Setup

1. **Create a free account** at [healthchecks.io](https://healthchecks.io) — free tier gives you 20 checks.

2. **Create a new check**:
   - Click **"New Check"**
   - **Name**: `VPS Backup`
   - **Schedule**: `Cron` → `17 3 * * 0` (same as your cron)
   - **Grace time**: `1 hour` (default — enough for even a large backup)

3. **Copy the Ping URL** — looks like:
   ```
   https://hc-ping.com/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
   ```

4. **Paste it into the deployed script** on your VPS:
   ```bash
   sudo nano /usr/local/bin/backup.sh
   ```
   Find:
   ```
   HEALTHCHECK_URL=""   # optional — fill in uuid from healthchecks.io
   ```
   Replace with:
   ```
   HEALTHCHECK_URL="https://hc-ping.com/your-uuid-here"
   ```

5. **Configure notifications** (email, Telegram, Discord, Slack, etc.) in healthchecks.io under **Integrations**.

### How it works

The script pings three times:

| When | Ping | Effect |
|---|---|---|
| Start | `$HEALTHCHECK_URL/start` | healthchecks measures how long the run takes |
| Success | `$HEALTHCHECK_URL`, with the run's log as body | check goes up |
| Failure | `$HEALTHCHECK_URL/fail`, with the run's log as body | alert right away, carrying the reason |

If no ping arrives within the grace time (the server is down, cron didn't run),
healthchecks alerts too. Note that it alerts **once**, when the check goes down,
not again for every missed run: a check that stays red stays quiet.

---

## Manual Backup

```bash
sudo /usr/local/bin/backup.sh
tail -f /var/log/backup.log
```

---

## Uninstall

From the VPS:

```bash
sudo bash /tmp/uninstall.sh
```

Or manually if you know what to target. The script removes (interactively):
- Cron job
- `/usr/local/bin/backup.sh`
- `/var/backups/vps` (optional)
- `/var/log/backup.log` (optional)
- rclone remote `b2-vps` (optional)

The Backblaze bucket and its files are **not** touched — delete those from the Backblaze dashboard.

---

## Files

| File | Purpose |
|---|---|
| `backup.sh` | The backup script deployed to `/usr/local/bin/backup.sh` |
| `setup.sh` | One-command VPS setup (rclone, cron, first backup) |
| `uninstall.sh` | Removes cron, script, logs, rclone remote (interactive) |
| `README.md` | This document |
