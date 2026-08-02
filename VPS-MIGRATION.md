# Move to VPS — checklist (reviewed 2026-08-02)

The setup was clearly built for a Rocky Linux VPS from day one (SELinux `:Z`,
loopback-only ports, cap_drop, mem limits, log rotation). Very little needs to
change. Below: what to do, in order, plus the 3 traps that WILL bite.

## The 3 traps

### 1. CPU architecture (Mac arm64 → VPS x86_64)
`data/openclaw/npm/` is **712 MB** of packages installed *inside the Linux/arm64
container* on your Mac. On an x86_64 VPS those binaries are the wrong
architecture and will fail in weird ways.

→ Do NOT copy `data/openclaw/npm`. Let the container rebuild it.
The Docker image itself is also rebuilt on the VPS (`--build`), so that's fine.

### 2. File ownership (uid mismatch)
On the Mac, Docker Desktop hides uid problems. On Linux it doesn't.
The container user `openclaw` is created with `useradd` in the Dockerfile —
in `node:22-bookworm` the `node` user already owns uid 1000, so `openclaw`
is likely **uid 1001**, while files you `rsync` up will be owned by your ssh
user (often uid 1000).

After copying, on the VPS:
```bash
docker compose up -d --build          # build first so the image exists
docker compose exec openclaw id      # note the uid (e.g. 1001)
docker compose down
sudo chown -R 1001:1001 data workspace certs   # use the uid you saw
docker compose up -d
```

### 3. Stop before you copy
Sessions/state (`data/openclaw/state`, `agents/`) are live files. Copying while
the gateway runs = possibly corrupt state.
```bash
docker compose down     # on the Mac, before the final rsync
```

## Transfer

```bash
# from the Mac (after docker compose down):
rsync -avz --progress \
  --exclude 'data/openclaw/npm' \
  --exclude '.DS_Store' \
  ~/Claude/Projects/hungnc2-assistant/ user@vps:~/hungnc2-assistant/

# .env goes with it (it's in the folder) — verify perms on the VPS:
ssh user@vps 'chmod 600 ~/hungnc2-assistant/.env'
```

What carries over without re-login (all inside `data/`):
- Claude Code OAuth → `data/claude`
- Codex OAuth → `data/codex` + `data/openclaw/acpx/codex-home/auth.json`
- gh/git credentials → `data/openclaw/gh`, `git-credentials`, `gh-token`
- Notion token + 3 db-id files
- Telegram pairing / owner id → `data/openclaw/openclaw.json`
- cron job "morning-review", agents list, all config

## On the VPS: one script

```bash
cd ~/hungnc2-assistant
./scripts/setup-vps.sh
```

It handles Docker install, swap, firewall (Ubuntu/Rocky auto-detected),
the arch-stale npm cache (trap #1), ownership fix (trap #2), compose build,
setup-acp.sh, and the Notion extras. Idempotent — re-run anytime.

If a login didn't survive the move:
- claude: `./scripts/setup-acp.sh claude` (URL flow works over ssh)
- codex: needs the browser callback →
  `ssh -L 1455:127.0.0.1:1455 user@vps` first, then `./scripts/codex-login.sh`

Dashboard (18789) and miniapp (8788) stay loopback-only — reach them with:
```bash
ssh -L 18789:127.0.0.1:18789 -L 8788:127.0.0.1:8788 user@vps
```

## Smoke tests (same as README §8)

1. Telegram message → pairing code → `docker compose exec openclaw openclaw pairing approve <code>`
   (pairing DB moved with you, so your chat should already be approved — test by just messaging)
2. `/acp doctor` from Telegram
3. `~/workspace/bin/personal-task list today` via a chat message
4. Wait for (or force-run) the 9:00 cron:
   `docker compose exec openclaw openclaw cron run <jobId> --wait`

## VPS hardening (once)

Handled automatically by `./scripts/setup-vps.sh` (detects Ubuntu → ufw,
Rocky → firewalld). Manual equivalent:

```bash
# Ubuntu:
sudo ufw default deny incoming && sudo ufw allow ssh && sudo ufw --force enable
# Rocky:
sudo firewall-cmd --set-default-zone=drop
sudo firewall-cmd --zone=drop --add-service=ssh --permanent
sudo firewall-cmd --reload
```
Everything the assistant does is outbound; no ports need opening.
`permissionMode=approve-all` is safe *only* as long as nothing inbound is exposed
and Telegram dmPolicy stays `pairing` — both are already the case.

## Backups (set up on VPS day 1)

Everything that matters is `data/` + `workspace/` + `.env`.
```bash
# /etc/cron.daily/backup-assistant (example)
cd ~/hungnc2-assistant && docker compose stop openclaw >/dev/null
tar czf ~/backups/assistant-$(date +%F).tar.gz --exclude data/openclaw/npm data workspace .env
docker compose start openclaw >/dev/null
find ~/backups -name 'assistant-*.tar.gz' -mtime +14 -delete
```

## Small cleanups (optional, not blockers)

- `setup-goals.sh` has a hardcoded `DEFAULT_PAGE_ID` — fine, it's yours, but note it.
- Folder is not a git repo. Consider `git init` + private repo with `.gitignore`
  covering `.env`, `data/`, `certs/` — the scripts and compose file deserve history.
- 5 rotating `openclaw.json.bak.*` files exist — the app manages these; ignore.
- `OPENCLAW_MEM_LIMIT=2g` — make sure the VPS has ≥4 GB RAM (2g container + OS + miniapp).
