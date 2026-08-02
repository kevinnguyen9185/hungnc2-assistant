#!/usr/bin/env bash
# =============================================================================
# codex-login.sh — browser-based `codex login` for a containerized codex.
#
# Why this exists:
#   `codex login` starts its OAuth callback server on localhost:1455 INSIDE
#   the container. Docker port forwarding can only reach the container's
#   network interface, never its localhost. So docker-compose maps
#   host 127.0.0.1:1455 → container :1456, and this script runs a tiny
#   relay (container 0.0.0.0:1456 → container 127.0.0.1:1455) for the
#   duration of the login, then cleans it up.
#
# Usage:  ./scripts/codex-login.sh
#   → copy the printed https://auth.openai.com/... URL into your browser,
#     approve, and the redirect to localhost:1455 lands where it should.
# =============================================================================
set -euo pipefail

CONTAINER="${CONTAINER:-hungnc2-assistant}"

docker exec -it "$CONTAINER" bash -c '
  node -e "
    const net = require(\"net\");
    net.createServer((s) => {
      const c = net.connect(1455, \"127.0.0.1\");
      s.pipe(c); c.pipe(s);
      s.on(\"error\", () => c.destroy());
      c.on(\"error\", () => s.destroy());
    }).listen(1456, \"0.0.0.0\");
  " &
  RELAY=$!
  trap "kill $RELAY 2>/dev/null" EXIT
  codex login
'

# Sync the fresh login into the ISOLATED home the acpx Codex adapter really
# uses (~/.openclaw/acpx/codex-home) — without this, ACP sessions fail with
# "Authentication required" even though `codex login status` says logged in.
docker exec "$CONTAINER" bash -c '
  ch="$HOME/.openclaw/acpx/codex-home"; mkdir -p "$ch"
  if [ -f "$HOME/.codex/auth.json" ]; then
    cp "$HOME/.codex/auth.json" "$ch/auth.json" && chmod 600 "$ch/auth.json"
    echo "codex-home auth synced"
  fi
'
