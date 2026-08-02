#!/usr/bin/env bash
# =============================================================================
# setup-acp.sh — one command to configure OpenClaw + wire up ACP workers
#
# Philosophy: NO hand-written openclaw.json. All config is applied through
# the official OpenClaw CLI / targeted patches, so it always matches the
# installed version (docs: docs.openclaw.ai/providers/openrouter and
# docs.openclaw.ai/tools/acp-agents/).
#
# Folder structure (host ↔ container), defined in docker-compose.yml:
#   ./data/openclaw  ↔ ~/.openclaw   gateway config + acpx state
#     └── acpx/codex-home/           ISOLATED home the Codex ACP adapter
#                                    actually runs with (auth.json must be
#                                    synced here — see sync_codex_acp_home)
#   ./data/claude    ↔ ~/.claude     Claude Code subscription login
#   ./data/codex     ↔ ~/.codex      Codex subscription login (host copy)
#   ./workspace      ↔ ~/workspace   shared brain; projects/ = agents' cwd
#
# Steps:
#   1. Telegram channel from .env
#   2. Default model: DeepSeek v4 Flash via OpenRouter
#   3. acpx plugin (install, enable, approve-all) + one agent per worker
#   4. Worker logins (claude, codex) + codex-home auth sync
#   5. Gateway restart + doctor
#
# Usage (from the folder containing docker-compose.yml):
#   ./scripts/setup-acp.sh                 # default agents: claude codex
#   ./scripts/setup-acp.sh claude          # just one
#
# Idempotent: safe to re-run anytime (expired token, new machine, update).
# =============================================================================
set -euo pipefail

CONTAINER="${CONTAINER:-hungnc2-assistant}"
MODEL_REF="${MODEL_REF:-openrouter/deepseek/deepseek-v4-flash}"
PROJECTS_DIR="/home/openclaw/workspace/projects"
AGENTS=("$@")
[[ ${#AGENTS[@]} -eq 0 ]] && AGENTS=(claude codex)

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
ok()    { printf '  \033[32m✔\033[0m %s\n' "$*"; }
warn()  { printf '  \033[33m⚠\033[0m %s\n' "$*"; }
fail()  { printf '  \033[31m✘\033[0m %s\n' "$*"; }

# plain `bash -c`, NOT `bash -lc`: a login shell re-reads /etc/profile,
# which resets PATH and loses the npm-global dir where openclaw lives.
in_ct()    { docker exec "$CONTAINER" bash -c "$*"; }
in_ct_it() { docker exec -it "$CONTAINER" bash -c "$*"; }

# --- 0. container up (and not crash-looping)? --------------------------------
bold "[0/5] Checking container '$CONTAINER'..."
if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  fail "Container not running. Start it first:  docker compose up -d --build"
  exit 1
fi
# "listed" is not "healthy": a crash-looping container also shows up in
# docker ps. Wait briefly for a stable running state.
state=""; restarting=""
for _ in 1 2 3 4 5 6; do
  state=$(docker inspect -f '{{.State.Status}}' "$CONTAINER")
  restarting=$(docker inspect -f '{{.State.Restarting}}' "$CONTAINER")
  [[ "$state" == "running" && "$restarting" == "false" ]] && break
  sleep 5
done
if [[ "$state" != "running" || "$restarting" != "false" ]]; then
  fail "Container is crash-looping (state=$state). Look at why it dies:"
  echo "     docker logs --tail 50 $CONTAINER"
  exit 1
fi
ok "container is running (stable)"

# --- 1. Telegram channel (token comes from .env → container env) -------------
bold "[1/5] Telegram channel"
if in_ct 'test -n "${TELEGRAM_BOT_TOKEN:-}"'; then
  in_ct 'openclaw config set channels.telegram.enabled true'
  in_ct 'openclaw config set channels.telegram.botToken "$TELEGRAM_BOT_TOKEN"'
  # Strict by default: unknown senders get a pairing code until you approve.
  in_ct 'openclaw config set channels.telegram.dmPolicy pairing'
  ok "telegram configured (dmPolicy=pairing)"
else
  warn "TELEGRAM_BOT_TOKEN not set in .env — skipping telegram channel"
fi

# --- 2. Model provider: DeepSeek v4 Flash via OpenRouter ----------------------
bold "[2/5] Model provider ($MODEL_REF)"
if in_ct 'test -n "${OPENROUTER_API_KEY:-}"'; then
  ok "OPENROUTER_API_KEY present in container env"
else
  warn "OPENROUTER_API_KEY missing in .env — starting interactive key login:"
  in_ct_it 'openclaw models auth login --provider openrouter --method api-key'
fi
in_ct "openclaw models set $MODEL_REF"
ok "default model set to $MODEL_REF"

# --- 2b. GitHub: the sync backbone ---------------------------------------------
# GH_TOKEN (PAT from .env) lets workers create/pull/push repos, and lets YOU
# work on the same repos from your laptop — GitHub is the source of truth.
# gh reads GH_TOKEN from env by itself; setup-git teaches plain `git` to use it.
#
# IMPORTANT — why we don't rely on the env var at agent runtime:
#   GH_TOKEN exists in the gateway process, but agent/harness tool shells run
#   with a filtered environment (secrets stripped), so an agent asking for
#   $GH_TOKEN sees it EMPTY. Fix: persist the credential to a file inside the
#   mounted ./data/openclaw volume and point git's credential store at it.
#   That survives rebuilds AND works without any env var.
bold "[2b/5] GitHub credentials"
if in_ct 'test -n "${GH_TOKEN:-}"'; then
  # 1. token → persisted credential file (chmod 600, same trust level as .env)
  in_ct 'cf="$HOME/.openclaw/git-credentials";
    printf "https://x-access-token:%s@github.com\n" "$GH_TOKEN" > "$cf";
    chmod 600 "$cf"'
  # 2. git (any process, any env) reads that file
  in_ct 'git config --global credential.helper "store --file=$HOME/.openclaw/git-credentials"'
  # 3. gh CLI: persist auth into GH_CONFIG_DIR (files in the ./data volume)
  #    so `gh` works in agent shells where env vars are FILTERED OUT.
  #    (Requires GH_CONFIG_DIR=/home/openclaw/.openclaw/gh in compose env.)
  in_ct 'mkdir -p "$HOME/.openclaw/gh" && printf "%s" "$GH_TOKEN" | \
    env GH_TOKEN= GITHUB_TOKEN= gh auth login --with-token --hostname github.com' \
    && ok "gh auth persisted to file (survives filtered env + rebuilds)" \
    || warn "gh auth login --with-token failed"
  in_ct 'gh auth setup-git' 2>/dev/null || true
  in_ct 'git config --global user.name  "${GIT_AUTHOR_NAME:-hungnc2-assistant}"'
  in_ct 'git config --global user.email "${GIT_AUTHOR_EMAIL:-hungnc2@vng.com.vn}"'
  # 4. also drop the token where agents CAN read it deliberately, so a worker
  #    can use `gh` in its own shell (GH_TOKEN=$(cat ...) gh ...).
  in_ct 'printf "%s" "$GH_TOKEN" > "$HOME/.openclaw/gh-token" && chmod 600 "$HOME/.openclaw/gh-token"'
  in_ct 'gh auth status' && ok "gh + git wired (persisted credential file)" \
    || warn "gh auth status failed — check the token's scopes/expiry"
  ok "git credential store: ~/.openclaw/git-credentials (survives rebuilds)"
else
  warn "GH_TOKEN not set in container env — workers can't push to GitHub."
  echo "     NOTE: editing .env needs 'docker compose up -d' (recreate);"
  echo "     'docker restart' keeps the OLD environment."
fi

# --- 3. acpx plugin + agent definitions ---------------------------------------
# Plugin/infra BEFORE logins, so post-login sync steps have a home to sync to.
bold "[3/5] ACP plugin (@openclaw/acpx) + agents"
if in_ct "openclaw plugins list 2>/dev/null | grep -q acpx"; then
  ok "@openclaw/acpx already installed"
else
  in_ct "openclaw plugins install @openclaw/acpx"
  ok "installed"
fi
in_ct "openclaw config set plugins.entries.acpx.enabled true"
# Headless = nobody can click "approve", so writes/exec must be pre-approved
# or every session dies at its first permission prompt. This is the power
# dial AND the danger dial — guardrails live in workspace/projects/CLAUDE.md.
in_ct "openclaw config set plugins.entries.acpx.config.permissionMode approve-all"
ok "enabled, permissionMode=approve-all"

# Define one OpenClaw agent per worker (docs: /tools/acp-agents "Runtime
# defaults per agent"). Without this, /acp spawn <id> binds the chat to
# agent id "<id>" but message routing fails with:
#   INVALID_REQUEST unknown agent id "<id>"
# config set can't write arrays, so we patch the config with jq (idempotent).
for agent in "${AGENTS[@]}"; do
  in_ct "f=\"\$HOME/.openclaw/openclaw.json\";
    if ! jq -e '.agents.list[]? | select(.id==\"$agent\")' \"\$f\" >/dev/null 2>&1; then
      jq '.agents.list = ((.agents.list // []) + [{
        id: \"$agent\",
        name: \"$agent\",
        workspace: \"$PROJECTS_DIR\",
        runtime: { type: \"acp\", acp: {
          agent: \"$agent\", backend: \"acpx\",
          mode: \"persistent\", cwd: \"$PROJECTS_DIR\"
        } }
      }])' \"\$f\" > \"\$f.tmp\" && mv \"\$f.tmp\" \"\$f\"
    fi;
    # \"workspace\" matters even with acp.cwd set: coordinator spawns
    # (sessions_spawn without cwd) inherit the TARGET AGENT'S workspace —
    # without it they land in ~/.openclaw/workspace-<id> instead of the repo.
    jq '.agents.list = [.agents.list[] | if .id==\"$agent\" then . + {workspace: \"$PROJECTS_DIR\"} else . end]' \
      \"\$f\" > \"\$f.tmp\" && mv \"\$f.tmp\" \"\$f\""
  ok "agent \"$agent\" defined (workspace + cwd = $PROJECTS_DIR)"
done

# --- codex-home sync (the fix that made codex actually work) ------------------
# The acpx Codex adapter runs codex with an ISOLATED home at
# ~/.openclaw/acpx/codex-home — it does NOT read ~/.codex at session time
# (despite what the docs suggest). Two consequences:
#   * auth.json must be copied there, or every session fails with
#     "ACP_SESSION_INIT_FAILED: Authentication required"
#   * the projects cwd must be trusted there, or codex silently stalls on a
#     "do you trust this directory?" prompt nobody can answer over chat.
# Idempotent; also re-syncs a fresh login over a stale copy.
sync_codex_acp_home() {
  in_ct "ch=\"\$HOME/.openclaw/acpx/codex-home\"; mkdir -p \"\$ch\";
    if [ -f \"\$HOME/.codex/auth.json\" ]; then
      cp \"\$HOME/.codex/auth.json\" \"\$ch/auth.json\" && chmod 600 \"\$ch/auth.json\";
    fi;
    cfg=\"\$ch/config.toml\"; touch \"\$cfg\";
    # OpenClaw REGENERATES this file sometimes — re-run this script if codex
    # suddenly loses auth/trust. workspace-write lets codex edit repo files
    # (its own sandbox layer; approvals are handled by acpx approve-all).
    grep -q '^sandbox_mode' \"\$cfg\" || printf '\nsandbox_mode = \"workspace-write\"\n' >> \"\$cfg\";
    # Shared memory NOTES.md lives one level ABOVE the projects cwd, so
    # workspace-write blocks it (\"fs sandbox helper failed\"). Grant the
    # whole workspace as an extra writable root.
    grep -q 'writable_roots' \"\$cfg\" || printf 'writable_roots = [\"/home/openclaw/workspace\"]\n' >> \"\$cfg\";
    if ! grep -qF '[projects.\"$PROJECTS_DIR\"]' \"\$cfg\"; then
      printf '\n[projects.\"%s\"]\ntrust_level = \"trusted\"\n' '$PROJECTS_DIR' >> \"\$cfg\";
    fi"
  ok "codex-home synced (auth.json + trusted $PROJECTS_DIR)"
}

# --- 4. worker logins ----------------------------------------------------------
check_binary() {
  case "$1" in
    claude) in_ct "command -v claude"  >/dev/null ;;
    codex)  in_ct "command -v codex"   >/dev/null ;;
    *)      return 1 ;;
  esac
}

install_hint() {
  case "$1" in
    claude) echo "npm install -g @anthropic-ai/claude-code" ;;
    codex)  echo "npm install -g @openai/codex" ;;
  esac
}

is_logged_in() {
  case "$1" in
    # cheap non-interactive probes; a failing probe just means "login needed".
    # `timeout` is essential: with a stale/unreachable token the claude CLI
    # retries for ages instead of failing — treat "slow" as "not logged in".
    claude) in_ct "timeout 30 claude -p 'ping' --max-turns 1" >/dev/null 2>&1 ;;
    codex)  in_ct "timeout 15 codex login status" >/dev/null 2>&1 ;;
  esac
}

do_login() {
  case "$1" in
    claude)
      warn "Claude Code headless login:"
      echo "     A URL will be printed. Open it in the browser on YOUR LAPTOP,"
      echo "     approve with the account that has your Claude subscription,"
      echo "     then paste the code back into this terminal."
      in_ct_it "claude /login || claude" ;;
    codex)
      warn "Codex browser login:"
      echo "     Copy the printed https://auth.openai.com/... URL into your"
      echo "     browser and approve with the account that has your ChatGPT"
      echo "     subscription. (codex-login.sh relays the localhost:1455"
      echo "     callback into the container — see comments in that script.)"
      CONTAINER="$CONTAINER" "$(dirname "$0")/codex-login.sh" ;;
  esac
}

post_login() {
  case "$1" in
    codex) sync_codex_acp_home ;;
    *)     : ;;
  esac
}

bold "[4/5] Worker logins"
FAILED=()
for agent in "${AGENTS[@]}"; do
  bold "  [agent: $agent]"
  if check_binary "$agent"; then
    ok "CLI installed"
  else
    fail "CLI missing in container. Add to Dockerfile:  $(install_hint "$agent")"
    FAILED+=("$agent"); continue
  fi

  if is_logged_in "$agent"; then
    ok "already logged in"
    post_login "$agent"
  else
    if do_login "$agent" && is_logged_in "$agent"; then
      ok "login stored (persists in ./data volume across rebuilds)"
      post_login "$agent"
    else
      fail "login incomplete — re-run: ./scripts/setup-acp.sh $agent"
      FAILED+=("$agent"); continue
    fi
  fi
done

# --- 5. restart + doctor -------------------------------------------------------
# config set changes (esp. permissionMode) need a gateway restart to apply.
bold "[5/5] Restart gateway + doctor"
docker restart "$CONTAINER" >/dev/null
ok "gateway restarted"
sleep 5
in_ct "openclaw doctor" || warn "doctor reported issues — read output above"

echo
if [[ ${#FAILED[@]} -gt 0 ]]; then
  fail "Needs attention: ${FAILED[*]}"
  exit 1
fi
bold "All set. From your Telegram chat with the bot:"
echo "  1. first message → pairing code → approve with:"
echo "     docker compose exec openclaw openclaw pairing approve <code>"
echo "  2. bind this chat to a worker:  /acp spawn claude --bind here"
echo "     (or codex; switch with /acp close first)"
echo "  3. health check from chat:      /acp doctor"
