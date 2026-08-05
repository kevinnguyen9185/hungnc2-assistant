#!/usr/bin/env bash
#
# openclaw-laptop-node.sh
# Setup OpenClaw node trên MacBook, kết nối tới Gateway trên VPS qua SSH tunnel.
#
# Cách dùng:
#   ./openclaw-laptop-node.sh              # setup tất cả (cài CLI + tunnel + node) - chạy 1 lần
#   ./openclaw-laptop-node.sh start        # bật tunnel + node
#   ./openclaw-laptop-node.sh stop         # tắt tunnel + node
#   ./openclaw-laptop-node.sh status       # xem trạng thái
#   ./openclaw-laptop-node.sh uninstall    # gỡ tunnel LaunchAgent + node service
#
set -euo pipefail

# ============ CONFIG (sửa ở đây nếu cần) ============
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Token gateway đọc từ .env của dự án (cùng file .env deploy lên VPS).
# Ưu tiên: biến môi trường có sẵn > ../.env (repo root) > ./.env
ENV_FILES=("$SCRIPT_DIR/../.env" "$SCRIPT_DIR/.env")

SSH_BIN="/usr/bin/ssh"
SSH_KEY="$HOME/.ssh/id_ed25519_hetzner"
SSH_USER="ubuntu"
SSH_HOST="135.181.85.161"
LOCAL_PORT="18790"           # port trên laptop
REMOTE_PORT="18789"          # port gateway trên VPS (loopback)
NODE_DISPLAY_NAME="Hung MacBook"

LABEL="ai.openclaw.ssh-tunnel"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
LOG_DIR="$HOME/Library/Logs/openclaw"
# ====================================================

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✔\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
err()  { printf '  \033[31m✘\033[0m %s\n' "$*"; }

# Đọc OPENCLAW_GATEWAY_TOKEN từ .env của dự án (nếu chưa có trong môi trường)
load_token() {
  if [ -n "${OPENCLAW_GATEWAY_TOKEN:-}" ]; then
    return 0
  fi
  local f line
  for f in "${ENV_FILES[@]}"; do
    [ -f "$f" ] || continue
    line=$(grep -E '^[[:space:]]*OPENCLAW_GATEWAY_TOKEN[[:space:]]*=' "$f" | tail -1 || true)
    [ -n "$line" ] || continue
    line="${line#*=}"                          # bỏ phần "TÊN_BIẾN="
    line="${line%\"}"; line="${line#\"}"       # bỏ nháy kép nếu có
    line="${line%\'}"; line="${line#\'}"       # bỏ nháy đơn nếu có
    line="$(echo "$line" | xargs)"             # bỏ khoảng trắng thừa
    if [ -n "$line" ]; then
      OPENCLAW_GATEWAY_TOKEN="$line"
      export OPENCLAW_GATEWAY_TOKEN
      TOKEN_SOURCE="$f"
      return 0
    fi
  done
  return 1
}
TOKEN_SOURCE="môi trường"

# Tìm openclaw kể cả khi chưa có trong PATH của shell hiện tại
find_openclaw() {
  if command -v openclaw >/dev/null 2>&1; then
    command -v openclaw
    return 0
  fi
  for p in "$HOME/.openclaw/bin/openclaw" \
           "/opt/homebrew/bin/openclaw" \
           "/usr/local/bin/openclaw"; do
    if [ -x "$p" ]; then echo "$p"; return 0; fi
  done
  return 1
}

# ---------- 1. Cài openclaw CLI ----------
install_cli() {
  bold "[1/3] OpenClaw CLI"
  if OPENCLAW_BIN=$(find_openclaw); then
    ok "Đã có sẵn: $OPENCLAW_BIN ($("$OPENCLAW_BIN" --version 2>/dev/null || echo '?'))"
    return 0
  fi
  warn "Chưa có openclaw, đang cài (installer chính thức, tự lo Node.js)..."
  curl -fsSL https://openclaw.ai/install.sh | bash -s -- --no-onboard
  if OPENCLAW_BIN=$(find_openclaw); then
    ok "Cài xong: $OPENCLAW_BIN"
  else
    err "Cài xong nhưng không tìm thấy lệnh 'openclaw'. Mở terminal mới rồi chạy lại script."
    exit 1
  fi
}

# ---------- 2. LaunchAgent cho SSH tunnel ----------
write_plist() {
  mkdir -p "$HOME/Library/LaunchAgents" "$LOG_DIR"
  cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${SSH_BIN}</string>
        <string>-N</string>
        <string>-o</string><string>ExitOnForwardFailure=yes</string>
        <string>-o</string><string>ServerAliveInterval=30</string>
        <string>-o</string><string>ServerAliveCountMax=3</string>
        <string>-o</string><string>StrictHostKeyChecking=accept-new</string>
        <string>-o</string><string>BatchMode=yes</string>
        <string>-i</string><string>${SSH_KEY}</string>
        <string>-L</string><string>${LOCAL_PORT}:127.0.0.1:${REMOTE_PORT}</string>
        <string>${SSH_USER}@${SSH_HOST}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/ssh-tunnel.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/ssh-tunnel.err.log</string>
</dict>
</plist>
PLIST_EOF
}

tunnel_loaded() {
  launchctl print "gui/$(id -u)/${LABEL}" >/dev/null 2>&1
}

tunnel_up() {
  # tunnel coi là "up" khi port local đang lắng nghe
  nc -z 127.0.0.1 "$LOCAL_PORT" >/dev/null 2>&1
}

setup_tunnel() {
  bold "[2/3] SSH tunnel (LaunchAgent)"
  if [ ! -f "$SSH_KEY" ]; then
    err "Không thấy SSH key: $SSH_KEY"
    exit 1
  fi
  if [ -f "$PLIST" ]; then
    ok "LaunchAgent đã tồn tại: $PLIST (ghi đè config mới nhất)"
  else
    ok "Tạo LaunchAgent: $PLIST"
  fi
  # Bootout trước nếu đang load, để nạp lại config mới
  tunnel_loaded && launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
  write_plist
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  ok "Tunnel đã được load (tự chạy khi login, tự nối lại khi rớt)"

  # Chờ tunnel lên tối đa ~15s
  for _ in $(seq 1 15); do
    tunnel_up && break
    sleep 1
  done
  if tunnel_up; then
    ok "Tunnel OK: 127.0.0.1:${LOCAL_PORT} → VPS:${REMOTE_PORT}"
  else
    err "Port ${LOCAL_PORT} chưa lên. Xem log: ${LOG_DIR}/ssh-tunnel.err.log"
    exit 1
  fi
}

# ---------- 3. OpenClaw node service ----------
setup_node() {
  bold "[3/3] OpenClaw node service"
  OPENCLAW_BIN=$(find_openclaw)
  # Token gateway: đọc từ .env của dự án (cùng token với VPS)
  if load_token; then
    ok "Dùng OPENCLAW_GATEWAY_TOKEN (nguồn: $TOKEN_SOURCE)"
    # Lưu vào config để node service (LaunchAgent) cũng đọc được,
    # vì LaunchAgent không thấy biến môi trường của shell này
    "$OPENCLAW_BIN" config set gateway.remote.token "$OPENCLAW_GATEWAY_TOKEN" || \
      warn "Không set được gateway.remote.token vào config (sẽ dựa vào env lúc install)"
  else
    warn "Không tìm thấy OPENCLAW_GATEWAY_TOKEN trong môi trường hoặc .env — nếu gateway có token, node sẽ bị từ chối (token_mismatch)"
  fi
  # Bật browser proxy TRƯỚC khi node kết nối, để node khai báo năng lực
  # browser ngay trong pairing request. Nếu bật sau khi đã pair, gateway
  # vẫn giữ snapshot caps cũ (rỗng) → phải revoke + approve lại trên VPS.
  "$OPENCLAW_BIN" config set nodeHost.browserProxy.enabled true || \
    warn "Không set được nodeHost.browserProxy.enabled — bật tay rồi restart node"
  ok "Browser proxy: enabled (cho phép gateway điều khiển browser trên máy này)"
  "$OPENCLAW_BIN" node install --host 127.0.0.1 --port "$LOCAL_PORT" --display-name "$NODE_DISPLAY_NAME" || true
  "$OPENCLAW_BIN" node start || true
  ok "Node service đã cài & chạy (kết nối tới 127.0.0.1:${LOCAL_PORT} qua tunnel)"
  echo
  bold "BƯỚC CUỐI - làm TRÊN VPS (pairing hết hạn sau 5 phút):"
  echo "    openclaw devices list"
  echo "    openclaw devices approve <requestId>"
  echo "    openclaw nodes status"
}

# ---------- Lệnh ----------
cmd_setup() {
  install_cli
  setup_tunnel
  setup_node
  echo
  bold "Xong! Kiểm tra bằng: $0 status"
}

cmd_start() {
  bold "Bật tunnel + node"
  if [ ! -f "$PLIST" ]; then
    err "Chưa có LaunchAgent. Chạy setup trước: $0"
    exit 1
  fi
  if tunnel_loaded; then
    launchctl kickstart -k "gui/$(id -u)/${LABEL}"
  else
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
  fi
  ok "Tunnel: đã bật"
  if OPENCLAW_BIN=$(find_openclaw); then
    load_token || true
    "$OPENCLAW_BIN" node start || true
    ok "Node: đã bật"
  fi
}

cmd_stop() {
  bold "Tắt tunnel + node"
  # Tắt tunnel TRƯỚC để nhả port ${LOCAL_PORT}.
  # Nếu tắt node trước, 'openclaw node stop' sẽ kiểm tra port này,
  # thấy SSH tunnel còn giữ (do KeepAlive) và báo lỗi "port is still busy".
  if tunnel_loaded; then
    launchctl bootout "gui/$(id -u)/${LABEL}"
    ok "Tunnel: đã tắt"
  else
    warn "Tunnel vốn không chạy"
  fi
  # Chờ port được nhả hẳn (tối đa 5s)
  for _ in $(seq 1 5); do
    tunnel_up || break
    sleep 1
  done
  if OPENCLAW_BIN=$(find_openclaw); then
    "$OPENCLAW_BIN" node stop || true
    ok "Node: đã tắt"
  fi
}

cmd_status() {
  bold "Trạng thái"
  if [ -f "$PLIST" ]; then ok "LaunchAgent: có ($PLIST)"; else warn "LaunchAgent: chưa tạo"; fi
  if tunnel_loaded; then ok "Tunnel: đang được launchd quản lý"; else warn "Tunnel: không load"; fi
  if tunnel_up; then ok "Port 127.0.0.1:${LOCAL_PORT}: đang mở (tunnel sống)"; else warn "Port 127.0.0.1:${LOCAL_PORT}: đóng (tunnel chết?)"; fi
  if load_token; then ok "Token: có (nguồn: $TOKEN_SOURCE)"; else warn "Token: không tìm thấy trong .env"; fi
  if OPENCLAW_BIN=$(find_openclaw); then
    bp=$("$OPENCLAW_BIN" config get nodeHost.browserProxy.enabled 2>/dev/null || echo "?")
    if [ "$bp" = "true" ]; then ok "Browser proxy: enabled"; else warn "Browser proxy: $bp (cần true để gateway điều khiển browser)"; fi
  fi
  if OPENCLAW_BIN=$(find_openclaw); then
    ok "openclaw CLI: $OPENCLAW_BIN"
    "$OPENCLAW_BIN" node status || true
  else
    warn "openclaw CLI: chưa cài"
  fi
}

cmd_uninstall() {
  bold "Gỡ cài đặt"
  if OPENCLAW_BIN=$(find_openclaw); then
    "$OPENCLAW_BIN" node stop || true
    "$OPENCLAW_BIN" node uninstall || true
    ok "Node service: đã gỡ"
  fi
  tunnel_loaded && launchctl bootout "gui/$(id -u)/${LABEL}" || true
  rm -f "$PLIST"
  ok "LaunchAgent: đã gỡ (không xoá openclaw CLI)"
}

case "${1:-setup}" in
  setup)     cmd_setup ;;
  start)     cmd_start ;;
  stop)      cmd_stop ;;
  status)    cmd_status ;;
  uninstall) cmd_uninstall ;;
  *)
    echo "Cách dùng: $0 [setup|start|stop|status|uninstall]"
    exit 1
    ;;
esac