#!/usr/bin/env bash
# =============================================================================
# setup-vps.sh — ONE script to prepare a fresh VPS and bring the assistant up.
#
# Works on BOTH Ubuntu (ufw) and Rocky Linux (firewalld) — OS is auto-detected.
#
# What it does (every step is idempotent — safe to re-run anytime):
#   [1] check specs (arch, RAM, disk) and OS
#   [2] install Docker + Compose if missing (official get.docker.com)
#   [3] create 2G swap if the box has none
#   [4] firewall: deny all inbound except ssh (ufw on Ubuntu, firewalld on Rocky)
#   [5] sanity: .env present + chmod 600, data dirs exist
#   [6] drop stale arch-specific npm cache (data/openclaw/npm) if migrating
#       from a different CPU arch (Mac arm64 → x86_64 VPS)
#   [7] docker compose up -d --build
#   [8] fix bind-mount ownership to match the container's uid (the classic
#       Linux gotcha that Docker Desktop on Mac hides)
#   [9] run scripts/setup-acp.sh  (telegram, model, gh, agents, logins)
#  [10] optional extras if configured: notion board, goals, morning reminder
#
# Usage (from the folder containing docker-compose.yml):
#   ./scripts/setup-vps.sh
#
# Interactive parts you cannot script away: claude/codex OAuth logins
# (step 9 prompts only when a login is missing) and Telegram pairing approval.
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")/.."          # always run from the compose folder
CONTAINER="${CONTAINER:-hungnc2-assistant}"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✔\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m⚠\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m✘\033[0m %s\n' "$*"; }

# docker may need sudo until the user re-logs after being added to the group
DOCKER() { if docker ps >/dev/null 2>&1; then docker "$@"; else sudo docker "$@"; fi; }

# --- [1] OS + specs -----------------------------------------------------------
bold "[1/10] OS + specs"
. /etc/os-release
OS_FAMILY=""
case "${ID:-}${ID_LIKE:-}" in
  *ubuntu*|*debian*) OS_FAMILY=debian ;;
  *rocky*|*rhel*|*fedora*|*centos*) OS_FAMILY=rhel ;;
  *) warn "unrecognized distro ($ID) — continuing, firewall step may be skipped" ;;
esac
ARCH=$(uname -m)
RAM_GB=$(awk '/MemTotal/{printf "%d", $2/1024/1024}' /proc/meminfo)
DISK_GB=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
ok "$PRETTY_NAME, $ARCH, ${RAM_GB}GB RAM, ${DISK_GB}GB free disk"
[[ "$RAM_GB"  -lt 4  ]] && warn "less than 4GB RAM — lower OPENCLAW_MEM_LIMIT in .env"
[[ "$DISK_GB" -lt 15 ]] && warn "less than 15GB free disk — image + data need ~15GB"

# --- [2] Docker ----------------------------------------------------------------
bold "[2/10] Docker"
if command -v docker >/dev/null 2>&1; then
  ok "already installed: $(docker --version)"
else
  curl -fsSL https://get.docker.com | sudo sh
  sudo systemctl enable --now docker
  ok "installed: $(sudo docker --version)"
fi
if ! id -nG "$USER" | grep -qw docker; then
  sudo usermod -aG docker "$USER"
  warn "added $USER to docker group — takes effect on NEXT login."
  warn "This run continues using sudo; re-login later for sudo-less docker."
fi

# --- [3] swap ------------------------------------------------------------------
bold "[3/10] Swap"
if [[ "$(awk '/SwapTotal/{print $2}' /proc/meminfo)" -gt 0 ]]; then
  ok "swap already present"
else
  sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile \
    && sudo mkswap /swapfile >/dev/null && sudo swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
  ok "2G swapfile created + persisted in /etc/fstab"
fi

# --- [4] firewall: nothing inbound except ssh -----------------------------------
bold "[4/10] Firewall"
if [[ "$OS_FAMILY" == "debian" ]] && command -v ufw >/dev/null 2>&1; then
  sudo ufw default deny incoming >/dev/null
  sudo ufw default allow outgoing >/dev/null
  sudo ufw allow ssh >/dev/null
  sudo ufw --force enable >/dev/null
  ok "ufw: deny inbound, allow ssh + all outbound"
elif [[ "$OS_FAMILY" == "rhel" ]] && command -v firewall-cmd >/dev/null 2>&1; then
  sudo systemctl enable --now firewalld >/dev/null 2>&1 || true
  sudo firewall-cmd --set-default-zone=drop >/dev/null
  sudo firewall-cmd --zone=drop --add-service=ssh --permanent >/dev/null
  sudo firewall-cmd --reload >/dev/null
  ok "firewalld: drop inbound, allow ssh"
else
  warn "no ufw/firewalld found — set up a firewall manually"
fi

# --- [5] .env + folders ----------------------------------------------------------
bold "[5/10] .env + folders"
if [[ ! -f .env ]]; then
  fail ".env missing. Either rsync it from the old machine, or:"
  echo "     cp .env.example .env && chmod 600 .env && nano .env"
  exit 1
fi
chmod 600 .env && ok ".env present (chmod 600)"
mkdir -p data/openclaw data/claude data/codex workspace certs
ok "data/ workspace/ certs/ exist"

# --- [6] stale npm cache from another CPU arch ------------------------------------
# data/openclaw/npm holds packages compiled for the arch they were installed on.
# Migrated from an arm64 Mac to x86_64 (or vice versa)? They're broken — drop
# them, the container rebuilds this automatically. Marker file remembers arch.
bold "[6/10] npm cache arch check"
MARKER="data/openclaw/.npm-arch"
if [[ -d data/openclaw/npm ]]; then
  if [[ -f "$MARKER" && "$(cat "$MARKER")" == "$ARCH" ]]; then
    ok "npm cache matches $ARCH — keeping"
  else
    sudo rm -rf data/openclaw/npm
    ok "removed npm cache (built for a different arch) — will be rebuilt"
  fi
fi
echo "$ARCH" | sudo tee "$MARKER" >/dev/null

# --- [7] build + start ------------------------------------------------------------
bold "[7/10] docker compose up -d --build"
DOCKER compose up -d --build
ok "containers started"

# --- [8] bind-mount ownership -------------------------------------------------------
# On Linux, files rsync'd up are owned by YOUR uid; the container user
# (openclaw, created after node's uid-1000 user) is usually uid 1001.
# Mismatch = "permission denied" inside the container.
bold "[8/10] Volume ownership"
CT_UID=$(DOCKER compose exec -T openclaw id -u openclaw | tr -dc '0-9')
CT_GID=$(DOCKER compose exec -T openclaw id -g openclaw | tr -dc '0-9')
HOST_UID=$(stat -c %u data/openclaw)
if [[ "$CT_UID" != "$HOST_UID" ]]; then
  DOCKER compose stop >/dev/null
  sudo chown -R "$CT_UID:$CT_GID" data workspace certs
  DOCKER compose start >/dev/null
  sleep 5
  ok "chowned data/ workspace/ certs/ to $CT_UID:$CT_GID (container user)"
else
  ok "ownership already correct (uid $CT_UID)"
fi

# --- [9] assistant wiring (existing script, idempotent) -----------------------------
bold "[9/10] setup-acp.sh (telegram, model, gh, agents, worker logins)"
if docker ps >/dev/null 2>&1; then
  ./scripts/setup-acp.sh
else
  warn "docker group not active yet in this shell."
  warn "Re-login (exit + ssh back), then run:  ./scripts/setup-acp.sh"
fi

# --- [10] optional extras, only when configured --------------------------------------
bold "[10/10] Optional extras"
if grep -q '^NOTION_API_KEY=..*' .env; then
  if grep -q '^NOTION_DB_ID=..*' .env; then
    ./scripts/setup-notion.sh && ok "notion task board synced"
  else
    warn "NOTION_API_KEY set but no NOTION_DB_ID — first run needs the page link:"
    echo "     ./scripts/setup-notion.sh <notion-page-link>"
  fi
  if grep -q '^NOTION_PERSONAL_DB_ID=..*' .env; then
    ./scripts/setup-goals.sh    && ok "goal dashboard synced"
    ./scripts/setup-reminder.sh && ok "9:00 morning reminder cron re-created"
  else
    warn "goals not set up yet — optional:  ./scripts/setup-goals.sh [page-link]"
  fi
else
  ok "no NOTION_API_KEY — skipping notion/goals/reminder"
fi

echo
bold "Done. Manual steps that can't be scripted:"
echo "  1. Message the bot on Telegram → get pairing code → approve:"
echo "       docker compose exec openclaw openclaw pairing approve <code>"
echo "     (skip if you migrated data/ — your pairing moved with it)"
echo "  2. Bind chat to a worker:   /acp spawn claude --bind here"
echo "  3. Health check:            /acp doctor"
echo "  4. Dashboard via tunnel:    ssh -L 18789:127.0.0.1:18789 $USER@<this-vps>"
