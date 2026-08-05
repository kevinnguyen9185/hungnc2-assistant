#!/usr/bin/env bash
#
# openclaw-laptop-node.sh
# Setup OpenClaw node trên MacBook, kết nối tới Gateway trên VPS qua SSH tunnel.
#
# Cách dùng:
#   ./openclaw-laptop-node.sh                 # setup tất cả (cài CLI + tunnel + node) - chạy 1 lần
#   ./openclaw-laptop-node.sh browser-pair    # cài + pair Chrome extension để lái Chrome thật (1 lần)
#   ./openclaw-laptop-node.sh start           # bật tunnel + node
#   ./openclaw-laptop-node.sh stop            # tắt tunnel + node
#   ./openclaw-laptop-node.sh status          # xem trạng thái
#   ./openclaw-laptop-node.sh uninstall       # gỡ tunnel LaunchAgent + node service
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
# Profile browser mặc định mà agent dùng:
#   chrome   = Chrome THẬT đang đăng nhập, lái qua OpenClaw extension, không popup consent
#   user     = Chrome thật, attach qua remote-debugging port, Chrome bắt bấm consent tại máy
#   openclaw = browser cô lập do OpenClaw tự quản (mặc định gốc của OpenClaw)
BROWSER_PROFILE="user"
GATEWAY_CONTAINER="hungnc2-assistant"   # tên container gateway trên VPS (cho phần in hướng dẫn)
# Account Chrome muốn agent dùng. Extension của Chrome được cài THEO TỪNG PROFILE,
# nên phải load nó đúng trong cửa sổ Chrome của account này, không thì agent sẽ
# điều khiển profile khác.
CHROME_ACCOUNT="hunggs.no7@gmail.com"
CHROME_USER_DATA_DIR="$HOME/Library/Application Support/Google/Chrome"

LABEL="ai.openclaw.ssh-tunnel"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
NODE_LABEL="ai.openclaw.node"
NODE_PLIST="$HOME/Library/LaunchAgents/${NODE_LABEL}.plist"
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

# Tra trong "Local State" của Chrome xem account CHROME_ACCOUNT nằm ở profile
# directory nào (Default / Profile 2 / ...). In ra: "<dir>|<tên hiển thị>|<có phải profile đang mặc định>"
# Rỗng nếu không tìm thấy.
chrome_profile_for_account() {
  [ -f "$CHROME_USER_DATA_DIR/Local State" ] || return 1
  CHROME_USER_DATA_DIR="$CHROME_USER_DATA_DIR" CHROME_ACCOUNT="$CHROME_ACCOUNT" python3 - <<'PY' 2>/dev/null
import json, os, sys
try:
    d = json.load(open(os.path.join(os.environ["CHROME_USER_DATA_DIR"], "Local State")))
except Exception:
    sys.exit(1)
prof = d.get("profile", {})
want = os.environ["CHROME_ACCOUNT"].strip().lower()
for dirname, info in (prof.get("info_cache") or {}).items():
    if (info.get("user_name") or "").strip().lower() == want:
        print(f"{dirname}|{info.get('name') or dirname}|{'yes' if prof.get('last_used') == dirname else 'no'}")
        sys.exit(0)
sys.exit(1)
PY
}

# Chrome có đang bật remote debugging không. Chrome 144+ không dùng cờ dòng lệnh
# nữa mà bật bằng toggle trong chrome://inspect; khi bật, Chrome ghi file
# DevToolsActivePort vào user data dir — Chrome DevTools MCP auto-connect dựa vào
# đúng file này. Không có file = profile 'user' sẽ lỗi
# "Could not find DevToolsActivePort".
chrome_remote_debug_on() {
  [ -f "$CHROME_USER_DATA_DIR/DevToolsActivePort" ]
}

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

node_loaded() {
  launchctl print "gui/$(id -u)/${NODE_LABEL}" >/dev/null 2>&1
}

# Quản lý node service TRỰC TIẾP bằng launchctl, không qua 'openclaw node
# start/stop' — CLI của openclaw có pre-check "port phải rảnh" và sẽ từ
# chối khi SSH tunnel (chủ đích) đang giữ port. Tiến trình node là client,
# không quan tâm port, nên nạp thẳng LaunchAgent là sạch nhất.
node_start_direct() {
  if [ ! -f "$NODE_PLIST" ]; then
    err "Chưa có $NODE_PLIST — chạy 'openclaw node install' trước"
    return 1
  fi
  if node_loaded; then
    launchctl kickstart -k "gui/$(id -u)/${NODE_LABEL}"
  else
    launchctl bootstrap "gui/$(id -u)" "$NODE_PLIST"
  fi
}

node_stop_direct() {
  node_loaded && launchctl bootout "gui/$(id -u)/${NODE_LABEL}" 2>/dev/null || true
}

tunnel_up() {
  # tunnel coi là "up" khi port local đang lắng nghe
  nc -z 127.0.0.1 "$LOCAL_PORT" >/dev/null 2>&1
}

# Chuẩn bị plist và đảm bảo tunnel ĐANG TẮT (port rảnh).
# Cần thiết vì 'openclaw node start' từ chối chạy khi port ${LOCAL_PORT}
# đang bị chiếm — kể cả khi người chiếm là chính tunnel của mình.
prepare_tunnel() {
  bold "[2/4] Chuẩn bị SSH tunnel (tạm tắt để nhả port cho node restart)"
  if [ ! -f "$SSH_KEY" ]; then
    err "Không thấy SSH key: $SSH_KEY"
    exit 1
  fi
  write_plist
  ok "LaunchAgent plist: $PLIST"
  tunnel_loaded && launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
  # Chờ port được nhả hẳn
  for _ in $(seq 1 10); do
    tunnel_up || break
    sleep 1
  done
  if tunnel_up; then
    err "Port ${LOCAL_PORT} vẫn bị chiếm dù đã tắt tunnel. Xem: lsof -i :${LOCAL_PORT}"
    exit 1
  fi
  ok "Port ${LOCAL_PORT} đã rảnh"
}

# Bật tunnel và chờ thông
start_tunnel() {
  bold "[4/4] Bật SSH tunnel"
  tunnel_loaded || launchctl bootstrap "gui/$(id -u)" "$PLIST"
  for _ in $(seq 1 15); do
    tunnel_up && break
    sleep 1
  done
  if tunnel_up; then
    ok "Tunnel OK: 127.0.0.1:${LOCAL_PORT} → VPS:${REMOTE_PORT}"
    ok "Node sẽ tự kết nối lại trong ~10 giây (vòng retry của node)"
  else
    err "Port ${LOCAL_PORT} chưa lên. Xem log: ${LOG_DIR}/ssh-tunnel.err.log"
    exit 1
  fi
}

# ---------- 3. OpenClaw node service ----------
setup_node() {
  bold "[3/4] OpenClaw node service (restart khi port đang rảnh)"
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
  # Bật browser plugin + browser proxy TRƯỚC khi node kết nối, để node
  # khai báo năng lực browser ngay trong pairing request. Nếu bật sau khi
  # đã pair, gateway vẫn giữ snapshot caps cũ → phải revoke + approve lại trên VPS.
  #
  # QUAN TRỌNG: browser.enabled / nodeHost.browserProxy.enabled KHÔNG kích hoạt
  # browser plugin trong plugin registry của node host. Caps mà node khai báo được
  # build từ nodeHostCommands của các plugin ĐÃ activate; nếu plugin browser không
  # activate thì không có command browser.proxy → không có cap "browser", và node
  # chỉ khai báo system + local-inference. plugins.entries.browser mới là công tắc
  # activate. Thiếu dòng này là lý do caps bị thiếu browser dù 2 flag dưới đã true.
  "$OPENCLAW_BIN" config set plugins.entries.browser.enabled true || \
    warn "Không set được plugins.entries.browser.enabled — node sẽ không khai báo cap browser"
  "$OPENCLAW_BIN" config set browser.enabled true || \
    warn "Không set được browser.enabled — bật tay rồi restart node"
  "$OPENCLAW_BIN" config set nodeHost.browserProxy.enabled true || \
    warn "Không set được nodeHost.browserProxy.enabled — bật tay rồi restart node"
  ok "Browser plugin + proxy: enabled (cho phép gateway điều khiển browser trên máy này)"
  # Dùng CHÍNH Chrome đang đăng nhập của mình, không phải browser 'openclaw' cô lập.
  #
  # Đang chọn 'user': driver existing-session, Chrome DevTools MCP auto-connect vào
  # profile MẶC ĐỊNH của Chrome (trên máy này Default = CHROME_ACCOUNT) — không phải
  # cài gì, nhưng Chrome bung popup "Allow remote debugging?" nên cần người ở máy,
  # và driver này thiếu vài action (click/type chỉ theo ref không theo selector,
  # không networkidle, không override timeoutMs).
  #
  # Muốn chạy được khi đi vắng thì đổi sang 'chrome': lái Chrome thật qua OpenClaw
  # Chrome extension (chrome.debugger API), không popup consent, ranh giới cho phép
  # là "OpenClaw tab group" (chỉ tab trong group mới bị thấy). Đổi BROWSER_PROFILE
  # ở đầu file rồi chạy: $0 setup && $0 browser-pair
  #
  # Cả 'chrome' và 'user' đều CHỈ ATTACH — không tự bật Chrome. Chrome phải đang mở.
  "$OPENCLAW_BIN" config set browser.defaultProfile "$BROWSER_PROFILE" || \
    warn "Không set được browser.defaultProfile=$BROWSER_PROFILE"
  ok "Browser profile mặc định: $BROWSER_PROFILE (Chrome thật của bạn, không phải profile 'openclaw')"
  # Stop hẳn rồi start lại để node đọc config mới (start khi đang chạy là no-op)
  node_stop_direct
  if [ ! -f "$NODE_PLIST" ]; then
    "$OPENCLAW_BIN" node install --host 127.0.0.1 --port "$LOCAL_PORT" --display-name "$NODE_DISPLAY_NAME" || true
  fi
  node_start_direct || err "Không start được node service — xem tail -30 $LOG_DIR/node.log"
  ok "Node service đã cài & chạy (kết nối tới 127.0.0.1:${LOCAL_PORT} qua tunnel)"
  echo
  bold "BƯỚC CUỐI - làm TRÊN VPS (pairing hết hạn sau 5 phút):"
  echo "  Pairing gồm 2 tầng, phải approve CẢ HAI:"
  echo "    openclaw devices list                      # tầng device (role: node)"
  echo "    openclaw devices approve <requestId>"
  echo "    openclaw nodes pending                     # tầng node, xuất hiện SAU khi approve device"
  echo "    openclaw nodes approve <requestId>"
  echo "    openclaw nodes status                      # kiểm tra caps phải có 'browser'"
  echo
  echo "  Gateway chạy trong docker thì thêm tiền tố:"
  echo "    docker exec ${GATEWAY_CONTAINER} openclaw ..."
  if [ "$BROWSER_PROFILE" = "chrome" ]; then
    echo
    bold "VÀ (1 lần duy nhất) cài Chrome extension để lái Chrome thật:"
    echo "    $0 browser-pair"
  elif [ "$BROWSER_PROFILE" = "user" ] && ! chrome_remote_debug_on; then
    echo
    bold "VÀ (1 lần duy nhất) bật remote debugging trong Chrome:"
    echo "    Mở  chrome://inspect  trong cửa sổ Chrome của $CHROME_ACCOUNT → tick 'Remote debugging'"
    echo "    Lần attach đầu Chrome sẽ hỏi consent → bấm cho phép."
    echo "    Kiểm tra lại bằng: $0 status"
  fi
}

# ---------- 4. Chrome extension (lái Chrome thật đang đăng nhập) ----------
# Bước này KHÔNG script hoá được hết: load unpacked extension phải làm tay trong
# chrome://extensions. Tách thành lệnh riêng thay vì nhét vào 'setup' vì lệnh
# 'pair' in ra SECRET (pairing string chứa token host-local), không nên để nó
# rơi vào log của mỗi lần setup.
cmd_browser_pair() {
  bold "Cài + pair OpenClaw Chrome extension (chỉ cần làm 1 lần cho mỗi máy)"
  OPENCLAW_BIN=$(find_openclaw) || { err "Chưa có openclaw CLI"; exit 1; }

  local ext_path
  ext_path=$("$OPENCLAW_BIN" browser extension path 2>/dev/null | tail -1)
  if [ -z "$ext_path" ] || [ ! -d "$ext_path" ]; then
    err "Không lấy được đường dẫn extension. Thử: $OPENCLAW_BIN browser extension path"
    exit 1
  fi

  # Extension của Chrome cài theo từng profile → phải load đúng cửa sổ của account
  # muốn dùng, nếu không agent sẽ điều khiển profile khác.
  local prof_info prof_dir prof_name prof_is_default
  if prof_info=$(chrome_profile_for_account); then
    prof_dir="${prof_info%%|*}"
    prof_name="$(echo "$prof_info" | cut -d'|' -f2)"
    prof_is_default="$(echo "$prof_info" | cut -d'|' -f3)"
    bold "0) Mở đúng cửa sổ Chrome của $CHROME_ACCOUNT"
    ok "Account này là profile \"$prof_name\" (thư mục: $prof_dir)"
    if [ "$prof_is_default" = "yes" ]; then
      ok "Đây cũng là profile Chrome đang mặc định (last_used)"
    else
      warn "Đây KHÔNG phải profile Chrome mở mặc định — nhớ chuyển đúng cửa sổ trước khi load"
    fi
    echo "    Mở cửa sổ của profile này:"
    echo "      open -na \"Google Chrome\" --args --profile-directory=\"$prof_dir\""
    echo
  else
    warn "Không tra được profile của $CHROME_ACCOUNT trong $CHROME_USER_DATA_DIR/Local State"
    warn "Tự kiểm tra: phải load extension trong cửa sổ Chrome đã đăng nhập $CHROME_ACCOUNT"
    echo
  fi

  bold "1) Load extension vào Chrome (LÀM TRONG CỬA SỔ Ở BƯỚC 0)"
  echo "    Mở  chrome://extensions  → bật Developer mode → Load unpacked → chọn:"
  echo "      $ext_path"
  command -v pbcopy >/dev/null 2>&1 && printf '%s' "$ext_path" | pbcopy && \
    ok "Đã copy đường dẫn vào clipboard (Cmd+Shift+G trong hộp thoại chọn thư mục rồi dán)"
  echo
  bold "2) Pair extension với node host trên máy này"
  echo "    Bấm icon OpenClaw trên toolbar Chrome → dán pairing string dưới đây vào popup."
  warn "Pairing string là SECRET (token host-local) — đừng paste vào chat/log/commit."
  echo
  "$OPENCLAW_BIN" browser extension pair || {
    err "Không tạo được pairing string. Node host đã chạy chưa? Xem: $0 status"
    exit 1
  }
  echo
  bold "3) Kiểm tra"
  echo "    Badge trên icon extension phải chuyển ON / popup ghi Connected."
  echo "    Trên VPS:  docker exec ${GATEWAY_CONTAINER} openclaw browser profiles"
  echo "               → dòng 'chrome' phải là [default] [extension] và running"
  echo
  bold "Cách dùng hằng ngày"
  echo "    Chia sẻ 1 tab cho agent: bấm icon OpenClaw trên tab đó (tab nhập 'OpenClaw' tab group)"
  echo "    Thu hồi: bấm lại, hoặc kéo tab ra khỏi group, hoặc tắt banner debug của Chrome"
  echo "    Agent chỉ thấy tab trong group — các tab khác vẫn riêng tư."
  echo
  echo "    Muốn dùng browser cô lập cho 1 lần gọi: profile=\"openclaw\""
  echo "    Muốn attach kiểu remote-debugging (phải bấm consent tại máy): profile=\"user\""
}

# ---------- Lệnh ----------
cmd_setup() {
  install_cli
  prepare_tunnel   # tắt tunnel → nhả port
  setup_node       # restart node khi port rảnh → check của openclaw pass
  start_tunnel     # bật lại tunnel → node tự nối lại
  echo
  bold "Xong! Kiểm tra bằng: $0 status"
}

cmd_start() {
  bold "Bật node + tunnel (node trước khi port rảnh, tunnel sau)"
  if [ ! -f "$PLIST" ]; then
    err "Chưa có LaunchAgent. Chạy setup trước: $0"
    exit 1
  fi
  # Tắt tunnel trước để 'node start' không bị lỗi "port busy"
  tunnel_loaded && launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
  for _ in $(seq 1 10); do
    tunnel_up || break
    sleep 1
  done
  load_token || true
  node_start_direct && ok "Node: đã bật" || err "Node không start được — xem $LOG_DIR/node.log"
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  for _ in $(seq 1 15); do
    tunnel_up && break
    sleep 1
  done
  if tunnel_up; then
    ok "Tunnel: đã bật — node sẽ tự nối lại trong ~10 giây"
  else
    err "Tunnel chưa lên. Xem log: ${LOG_DIR}/ssh-tunnel.err.log"
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
  node_stop_direct
  ok "Node: đã tắt"
}

cmd_status() {
  bold "Trạng thái"
  if [ -f "$PLIST" ]; then ok "LaunchAgent: có ($PLIST)"; else warn "LaunchAgent: chưa tạo"; fi
  if tunnel_loaded; then ok "Tunnel: đang được launchd quản lý"; else warn "Tunnel: không load"; fi
  if tunnel_up; then ok "Port 127.0.0.1:${LOCAL_PORT}: đang mở (tunnel sống)"; else warn "Port 127.0.0.1:${LOCAL_PORT}: đóng (tunnel chết?)"; fi
  if load_token; then ok "Token: có (nguồn: $TOKEN_SOURCE)"; else warn "Token: không tìm thấy trong .env"; fi
  if OPENCLAW_BIN=$(find_openclaw); then
    bpl=$("$OPENCLAW_BIN" config get plugins.entries.browser.enabled 2>/dev/null || echo "?")
    be=$("$OPENCLAW_BIN" config get browser.enabled 2>/dev/null || echo "?")
    bp=$("$OPENCLAW_BIN" config get nodeHost.browserProxy.enabled 2>/dev/null || echo "?")
    if [ "$bpl" = "true" ]; then ok "Browser plugin activate: enabled"; else warn "Browser plugin activate: $bpl (cần true, nếu không node sẽ KHÔNG khai báo cap browser)"; fi
    if [ "$be" = "true" ]; then ok "Browser plugin: enabled"; else warn "Browser plugin: $be (cần true)"; fi
    if [ "$bp" = "true" ]; then ok "Browser proxy: enabled"; else warn "Browser proxy: $bp (cần true để gateway điều khiển browser)"; fi
    dp=$("$OPENCLAW_BIN" config get browser.defaultProfile 2>/dev/null | tail -1 || echo "?")
    if [ "$dp" != "$BROWSER_PROFILE" ]; then
      warn "Browser profile mặc định: $dp — lệch với BROWSER_PROFILE=$BROWSER_PROFILE trong script (chạy: $0 setup)"
    else
      case "$dp" in
        chrome) ok "Browser profile mặc định: chrome (Chrome thật qua extension, không cần người bấm consent)" ;;
        user)   ok "Browser profile mặc định: user (Chrome thật qua remote-debugging; cần người ở máy khi Chrome hỏi consent)" ;;
        *)      warn "Browser profile mặc định: $dp — không phải Chrome thật của bạn (browser cô lập)" ;;
      esac
    fi
    # Relay chỉ liên quan tới profile 'chrome'. Với 'user' thì Chrome DevTools MCP
    # attach trực tiếp, không qua relay nên không cần check port 18799.
    # LƯU Ý: file browser-extension-relay.secret do node host tạo khi mở relay,
    # KHÔNG chứng minh là extension đã pair.
    if [ "$dp" = "chrome" ]; then
      if nc -z 127.0.0.1 18799 >/dev/null 2>&1; then
        ok "Extension relay: đang lắng nghe 127.0.0.1:18799"
      else
        warn "Extension relay: không mở (node host chưa chạy?)"
      fi
      echo "     ↳ extension đã pair chưa thì xem badge icon OpenClaw trong Chrome, hoặc trên VPS:"
      echo "       docker exec ${GATEWAY_CONTAINER} openclaw browser profiles   # dòng 'chrome' phải running"
    else
      if [ "$dp" = "user" ]; then
        if chrome_remote_debug_on; then
          ok "Chrome remote debugging: đã bật (có DevToolsActivePort)"
        else
          err "Chrome remote debugging: CHƯA bật → profile 'user' sẽ lỗi 'Could not find DevToolsActivePort'"
          echo "       Bật: mở chrome://inspect trong cửa sổ profile đích → tick 'Remote debugging'"
          echo "       (Chrome 144+ bật bằng toggle này, KHÔNG dùng cờ --remote-debugging-port nữa)"
        fi
      fi
      echo "     ↳ kiểm tra profile đang sống trên VPS:"
      echo "       docker exec ${GATEWAY_CONTAINER} openclaw browser profiles   # dòng '$dp' phải running"
      echo "     ↳ muốn chuyển sang extension (chạy được khi đi vắng): $0 browser-pair"
    fi
    if pinfo=$(chrome_profile_for_account); then
      ok "Chrome account đích: $CHROME_ACCOUNT → profile \"$(echo "$pinfo" | cut -d'|' -f2)\" (${pinfo%%|*})"
      [ "$(echo "$pinfo" | cut -d'|' -f3)" = "yes" ] || \
          warn "  profile này không phải last_used của Chrome — profile 'user' auto-connect vào profile mặc định của Chrome, dễ attach sai account"
    else
      warn "Chrome account đích: không tìm thấy $CHROME_ACCOUNT trong Local State của Chrome"
    fi
    if pgrep -qf "Google Chrome" 2>/dev/null; then
      ok "Chrome: đang chạy (bắt buộc — profile 'chrome'/'user' chỉ attach, KHÔNG tự bật Chrome)"
    else
      warn "Chrome: KHÔNG chạy → agent sẽ không có gì để attach. Mở Chrome trước khi ra lệnh."
    fi
  fi
  if node_loaded; then
    pid=$(launchctl print "gui/$(id -u)/${NODE_LABEL}" 2>/dev/null | grep -m1 'pid = ' | grep -o '[0-9]*' || true)
    ok "Node service: loaded${pid:+ (pid $pid)}"
  else
    warn "Node service: not loaded"
  fi
  if OPENCLAW_BIN=$(find_openclaw); then
    ok "openclaw CLI: $OPENCLAW_BIN"
  else
    warn "openclaw CLI: chưa cài"
  fi
}

cmd_uninstall() {
  bold "Gỡ cài đặt"
  node_stop_direct
  rm -f "$NODE_PLIST"
  ok "Node service: đã gỡ"
  tunnel_loaded && launchctl bootout "gui/$(id -u)/${LABEL}" || true
  rm -f "$PLIST"
  ok "LaunchAgent: đã gỡ (không xoá openclaw CLI)"
}

case "${1:-setup}" in
  setup)        cmd_setup ;;
  start)        cmd_start ;;
  stop)         cmd_stop ;;
  status)       cmd_status ;;
  browser-pair) cmd_browser_pair ;;
  uninstall)    cmd_uninstall ;;
  *)
    echo "Cách dùng: $0 [setup|start|stop|status|browser-pair|uninstall]"
    exit 1
    ;;
esac
