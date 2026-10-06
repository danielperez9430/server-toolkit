# 🧰 Server Toolkit

<p align="center">
  <img src="https://img.shields.io/badge/shell-bash-4EAA25?style=for-the-badge&logo=gnu-bash&logoColor=white" alt="Bash">
  <img src="https://img.shields.io/badge/platform-debian%20%7C%20ubuntu-E95420?style=for-the-badge&logo=ubuntu&logoColor=white" alt="Platform">
  <img src="https://img.shields.io/badge/license-MIT-green?style=for-the-badge" alt="License">
</p>

<p align="center">
  <strong>A growing collection of server automation scripts — UFW backup, port scanning, Caddy install/update, Docker setup, and more. Designed for quick, idempotent VPS provisioning and maintenance.</strong>
</p>

---

## 📦 What's Inside

| Script | What it does | Safe to re-run |
| --- | --- | :---: |
| [`ufw_backups.sh`](#ufw_backup--restore) | Backup, restore, list, and manage UFW firewall rulesets | ✅ |
| [`port_scanner.sh`](#port-scanner--manager) | Scan exposed ports, assess risk, close ports via UFW, identify listening processes | ✅ |
| [`setup_docker.sh`](#docker-setup) | Install Docker Engine from the official repo, optional build tooling | ✅ |
| [`caddy/setup_caddy.sh`](#caddy-setup) | Build and install Caddy with Cloudflare DNS plugin, systemd service, hardened permissions | ✅ |
| [`caddy/update_caddy.sh`](#caddy-update) | Rebuild latest Caddy, atomic binary swap, zero-downtime reload | ✅ |
| [`backup/`](backup/README.md) | Weekly backup to Backblaze B2 with a write-only key; finds live MySQL, PostgreSQL and SQLite databases and dumps them consistently | ✅ |

---

## 🚀 Quick Start

```bash
git clone https://github.com/danielperez9430/server-toolkit.git
cd server-toolkit

# Audit your firewall and ports
sudo bash ufw_backups.sh
sudo bash port_scanner.sh

# Set up Docker + Caddy on a fresh VPS
sudo bash setup_docker.sh --build
bash caddy/setup_caddy.sh
```

All scripts auto-detect Debian or Ubuntu. They install missing dependencies and skip work that's already done — so you can run them again without breaking anything.

---

## 🔥 UFW Backup & Restore

`ufw_backups.sh` — interactive menu for managing your UFW firewall rules.

**Menu options:**

| # | Action | Details |
| :-: | --- | --- |
| 1 | **Create backup** | Timestamped `.tar.gz` of all `.rules` files + `ufw.conf` + human-readable `ufw status verbose` |
| 2 | **Restore backup** | Pick from a list of saved backups. Creates a safety snapshot of current rules *before* overwriting, then reloads UFW |
| 3 | **List backups** | Browse all stored backups with file sizes |
| 4 | **View live rules** | Runs `ufw status verbose` in one keystroke |
| 5 | **Delete backup** | Clean up old snapshots |

Backups are stored under `$HOME/ufw_backups/`. The restore flow is deliberately cautious — it snapshots your current rules before touching anything, so you can always undo.

```bash
sudo bash ufw_backups.sh
```

---

## 🔎 Port Scanner & Manager

`port_scanner.sh` — interactive port audit with risk classification.

**Menu options:**

| # | Action | Details |
| :-: | --- | --- |
| 1 | **Scan exposed ports** | Lists every port listening on `0.0.0.0` or `::` (publicly reachable), annotated with service name and risk level |
| 2 | **Close an exposed port** | Blocks a selected port via `ufw deny`. Only shows ports you can actually close |
| 3 | **View all ports** | Full `ss -tulnp` dump, color-coded: cyan for exposed, dim for localhost-only |
| 4 | **Find process by port** | Cross-references `ss` and `lsof` to tell you exactly what's listening |
| 5 | **Risk summary** | Tally of low / medium / high risk ports with a verdict |

**Risk classification:**

| Level | Ports | Signal |
| :---: | --- | --- |
| 🟢 **Low** | 80, 443 | Web traffic — expected |
| 🟡 **Medium** | 22 | SSH — review key-only auth |
| 🔴 **High** | Everything else | Likely unintended exposure — close it |

Common ports get named automatically (MySQL → 3306, Redis → 6379, Postgres → 5432, MongoDB → 27017, Elasticsearch → 9200, RabbitMQ → 5672, and more).

```bash
sudo bash port_scanner.sh
```

---

## 🐳 Docker Setup

`setup_docker.sh` — installs Docker Engine from the [official Docker repository](https://docs.docker.com/engine/install/ubuntu/). Runs the full documented flow: purge old packages, add the GPG key, configure the apt source, install, enable the systemd unit, and optionally add your user to the `docker` group.

**Flags:**

| Flag | Effect |
| --- | --- |
| *(none)* | Runtime only — `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-compose-plugin` |
| `--build` | Runtime + build tooling — adds `docker-buildx-plugin` |

After installation, the script drops you into a fresh login shell so the `docker` group change takes effect immediately — no need to log out and back in.

```bash
sudo bash setup_docker.sh           # runtime only
sudo bash setup_docker.sh --build   # runtime + buildx for image builds
```

---

## 🌐 Caddy Setup

`caddy/setup_caddy.sh` — builds Caddy from source via `xcaddy` with the [Cloudflare DNS provider plugin](https://github.com/caddy-dns/cloudflare) baked in. This is the path you want when serving sites behind Cloudflare — DNS-01 challenges mean Caddy can obtain TLS certificates without opening port 80/443 to the world during validation.

**What it does:**

1. Installs `xcaddy` from the Cloudsmith repo
2. Builds Caddy with `--with github.com/caddy-dns/cloudflare`
3. Creates a locked-down `caddy` system user (`/usr/sbin/nologin`, no shell access)
4. Writes `/etc/caddy/`, `/var/lib/caddy/`, `/var/log/caddy/` with tight permissions (`750`)
5. Deploys a hardened systemd unit — `ProtectSystem=full`, `PrivateTmp=true`, no extra capabilities beyond `CAP_NET_BIND_SERVICE`
6. Enables the service but does **not** start it — you control when Caddy goes live

The service is *not* started automatically. You edit your `Caddyfile` first, then start it yourself.

```bash
bash caddy/setup_caddy.sh
```

**Next steps after setup:**

```bash
sudo nano /etc/caddy/Caddyfile    # add your domains + CF_API_TOKEN
sudo systemctl start caddy         # go live
sudo systemctl status caddy        # confirm
sudo journalctl -u caddy -f        # tail logs
```

---

## 🔄 Caddy Update

`caddy/update_caddy.sh` — fetches the latest Caddy release tag from GitHub, compares it to your installed version, rebuilds with the same plugin set, and swaps the binary in place.

**Safety guarantees:**

- **Pre-update backup** — current binary copied to `/usr/local/bin/caddy.bak` before the swap
- **Validation gate** — new binary is run with `caddy version` before it replaces the old one. If the build is broken, the script aborts and leaves your existing installation untouched
- **Atomic swap** — uses `mv` (same filesystem, so it's a rename — not a copy) to replace the running binary
- **Zero-downtime reload** — sends `systemctl reload caddy` if the service is active. Falls back to a full restart if reload fails
- **Temp directory cleanup** — build artifacts land in `mktemp -d`, cleaned up on exit via `trap`

If the running version already matches the latest tag, the script exits cleanly.

```bash
sudo bash caddy/update_caddy.sh
```

**Rollback (if needed):**

```bash
sudo systemctl stop caddy
sudo cp /usr/local/bin/caddy.bak /usr/local/bin/caddy
sudo systemctl start caddy
```

---

## 📂 Repo Structure

```
server-toolkit/
├── ufw_backups.sh          # UFW backup & restore
├── port_scanner.sh         # Port audit & risk assessment
├── setup_docker.sh         # Docker Engine installer
├── caddy/
│   ├── setup_caddy.sh      # Caddy + Cloudflare DNS plugin installer
│   └── update_caddy.sh     # Caddy updater (atomic swap)
├── LICENSE                 # MIT
└── README.md
```

---

## 🧠 Design Principles

| Principle | What it means in practice |
| --- | --- |
| **Idempotent** | Scripts check current state before acting. Re-running `setup_docker.sh` won't break an existing install. Re-running `update_caddy.sh` exits early if you're already on the latest version |
| **Safe by default** | Destructive operations are guarded. `ufw_backups.sh` snapshots your live rules before restoring. `update_caddy.sh` backs up the binary before swapping. `setup_docker.sh` drops into a login shell so group membership takes effect cleanly |
| **Composable** | Each script does one thing. Chain them together for provisioning. Use them individually for maintenance |
| **Interactive + scriptable** | Menu-driven scripts (`ufw_backups.sh`, `port_scanner.sh`) expose every action through numbered menus. Flag-driven scripts (`setup_docker.sh`, `update_caddy.sh`) work in pipelines |

---

## 📋 Requirements

- **OS:** Debian or Ubuntu (uses `apt` and `dpkg`)
- **Privileges:** `sudo` or root for most scripts
- **Network:** outbound internet access to fetch packages and GPG keys
- **Shell:** Bash 4+

---

## 📄 License

MIT — see [LICENSE](LICENSE).

---

<p align="center">
  <sub>Built for quick, repeatable VPS provisioning. PRs welcome for additional scripts that fit the philosophy.</sub>
</p>
