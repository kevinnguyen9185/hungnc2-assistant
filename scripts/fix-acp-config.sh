#!/usr/bin/env bash
#
# fix-spawn-allowlist.sh — cho phép spawn một ACP agent (mặc định: codex)
# qua sessions_spawn trong OpenClaw, một cách an toàn & idempotent.
#
# Cách dùng:
#   DRY_RUN=1 ./fix-spawn-allowlist.sh          # xem trước, KHÔNG sửa gì
#   ./fix-spawn-allowlist.sh                    # áp dụng cho "codex"
#   ./fix-spawn-allowlist.sh gemini             # áp dụng cho agent khác
#   SKIP_RESTART=1 ./fix-spawn-allowlist.sh     # sửa config nhưng tự restart sau
#
# Script này:
#   1. Backup config (kèm timestamp) trước khi đụng vào bất cứ thứ gì
#   2. Kiểm tra agent đích có tồn tại trong agents.entries không (fail sớm)
#   3. Thêm agent vào agents.defaults.subagents.allowAgents (nếu key có set)
#   4. Thêm agent vào MỌI per-agent override agents.entries.*.subagents.allowAgents
#      (vì override đè lên defaults — đây là chỗ hay bị sót nhất)
#   5. Thêm agent vào acp.allowedAgents (nếu key có set — lớp chặn thứ 2 của ACP)
#   6. Ghi config qua `openclaw config set` (không jq trực tiếp vào file,
#      tránh vỡ JSON5) và chỉ ghi khi thực sự cần thay đổi
#   7. Restart gateway rồi verify lại từng key đã sửa
#
set -euo pipefail

AGENT="${1:-codex}"
DRY_RUN="${DRY_RUN:-0}"
SKIP_RESTART="${SKIP_RESTART:-0}"

log()  { printf '\033[1;34m[i]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- 0. Preflight ----------
command -v openclaw >/dev/null 2>&1 || die "Không tìm thấy 'openclaw' CLI trong PATH."
command -v python3  >/dev/null 2>&1 || die "Cần python3 để xử lý JSON an toàn."

CONFIG_PATH="${OPENCLAW_CONFIG:-$HOME/.openclaw/openclaw.json}"

# ---------- 1. Backup ----------
BACKUP="(không có backup — file config không tìm thấy lúc chạy)"
if [ -f "$CONFIG_PATH" ]; then
  BACKUP="${CONFIG_PATH}.bak.$(date +%Y%m%d-%H%M%S)"
  if [ "$DRY_RUN" = "1" ]; then
    log "(dry-run) Sẽ backup: $CONFIG_PATH -> $BACKUP"
  else
    cp -p "$CONFIG_PATH" "$BACKUP"
    ok "Đã backup config: $BACKUP"
  fi
  # Cảnh báo mất comment: CLI ghi lại file dưới dạng JSON chuẩn
  # (chỉ bắt dòng bắt đầu bằng // hoặc /* để không nhầm với "https://")
  if grep -qE '^[[:space:]]*(//|/\*)' "$CONFIG_PATH" 2>/dev/null; then
    warn "Config đang có comment kiểu JSON5 — 'openclaw config set' sẽ xoá comment khi ghi. Backup ở trên giữ bản gốc."
  fi
else
  warn "Không thấy file config tại $CONFIG_PATH (CLI có thể dùng path khác) — bỏ qua bước backup file."
fi

# ---------- 2-5. Tính toán thay đổi (đọc qua CLI, không parse file thô) ----------
PLAN_FILE="$(mktemp)"
trap 'rm -f "$PLAN_FILE"' EXIT

# Không để set -e giết script trước khi kịp in thông báo lỗi rõ ràng
set +e
python3 - "$AGENT" > "$PLAN_FILE" <<'PY'
import json, subprocess, sys

agent = sys.argv[1]

def get(path):
    """Đọc 1 giá trị config qua CLI; trả về None nếu key chưa set."""
    try:
        r = subprocess.run(
            ["openclaw", "config", "get", path, "--json"],
            capture_output=True, text=True, timeout=30,
        )
        if r.returncode != 0:
            return None
        out = r.stdout.strip()
        return json.loads(out) if out else None
    except Exception:
        return None

def emit(path, new_value):
    print(f"{path}\t{json.dumps(new_value)}")

def note(msg):
    print(f"[note] {msg}", file=sys.stderr)

# --- Kiểm tra agent đích tồn tại ---
entries = get("agents.entries")
if not isinstance(entries, dict):
    # thử schema cũ hơn: agents.list
    lst = get("agents.list")
    if isinstance(lst, list):
        ids = {e.get("id") if isinstance(e, dict) else e for e in lst}
        if agent not in ids:
            print(f"[fatal] '{agent}' không có trong agents.list — phải khai báo agent trước.", file=sys.stderr)
            sys.exit(2)
        entries = {}
        note("Config dùng agents.list (schema cũ) — script chỉ sửa defaults + acp.allowedAgents.")
    else:
        print("[fatal] Không đọc được agents.entries lẫn agents.list từ config.", file=sys.stderr)
        sys.exit(2)
elif agent not in entries:
    print(f"[fatal] '{agent}' không có trong agents.entries — phải khai báo agent trước khi allow spawn.", file=sys.stderr)
    sys.exit(2)

def needs_add(cur):
    """True nếu cur là list, chưa có agent và không có wildcard."""
    return isinstance(cur, list) and "*" not in cur and agent not in cur

changed = 0

# --- (3) Global default ---
path = "agents.defaults.subagents.allowAgents"
cur = get(path)
if needs_add(cur):
    emit(path, cur + [agent]); changed += 1
elif cur is None:
    note(f"{path} chưa set — spawn sẽ do per-agent override quyết định.")
else:
    note(f"{path} đã OK ({json.dumps(cur)}).")

# --- (4) Mọi per-agent override ---
for aid, entry in (entries or {}).items():
    if not isinstance(entry, dict):
        continue
    cur = (entry.get("subagents") or {}).get("allowAgents")
    if cur is None:
        continue  # entry này dùng defaults -> đã xử lý ở trên
    path = f"agents.entries.{aid}.subagents.allowAgents"
    if needs_add(cur):
        emit(path, cur + [agent]); changed += 1
    else:
        note(f"{path} đã OK ({json.dumps(cur)}).")

# --- (5) Lớp chặn ACP ---
path = "acp.allowedAgents"
cur = get(path)
if needs_add(cur):
    emit(path, cur + [agent]); changed += 1
elif cur is None:
    note(f"{path} chưa set — mặc định cho phép mọi ACP agent đã cấu hình, không cần sửa.")
else:
    note(f"{path} đã OK ({json.dumps(cur)}).")

if changed == 0:
    note("Không có gì phải sửa — config đã cho phép sẵn.")
PY
PY_EXIT=$?
set -e
[ "$PY_EXIT" -eq 0 ] || die "Preflight thất bại (xem thông báo [fatal] phía trên)."

# ---------- 6. Áp dụng ----------
CHANGED=0
while IFS=$'\t' read -r path value; do
  [ -n "$path" ] || continue
  CHANGED=$((CHANGED + 1))
  if [ "$DRY_RUN" = "1" ]; then
    log "(dry-run) openclaw config set '$path' '$value' --strict-json"
  else
    openclaw config set "$path" "$value" --strict-json
    ok "Đã set $path = $value"
  fi
done < "$PLAN_FILE"

if [ "$CHANGED" -eq 0 ]; then
  ok "Config đã đúng từ trước — không thay đổi gì, không cần restart."
  exit 0
fi

if [ "$DRY_RUN" = "1" ]; then
  log "(dry-run) Kết thúc — chưa sửa gì cả. Chạy lại không có DRY_RUN=1 để áp dụng."
  exit 0
fi

# ---------- 7. Restart gateway ----------
if [ "$SKIP_RESTART" = "1" ]; then
  warn "SKIP_RESTART=1 — nhớ tự restart gateway để config có hiệu lực."
else
  log "Restart gateway..."
  if openclaw gateway restart 2>/dev/null; then
    ok "Gateway đã restart."
  elif systemctl --user restart openclaw 2>/dev/null || sudo -n systemctl restart openclaw 2>/dev/null; then
    ok "Gateway đã restart qua systemd."
  else
    warn "Không tự restart được — hãy restart thủ công (vd: 'openclaw gateway restart' hoặc 'systemctl restart openclaw')."
  fi
fi

# ---------- 8. Verify ----------
log "Verify lại các key vừa sửa:"
FAIL=0
while IFS=$'\t' read -r path expected; do
  [ -n "$path" ] || continue
  actual="$(openclaw config get "$path" --json 2>/dev/null || echo '<đọc lỗi>')"
  if [ "$(printf '%s' "$actual" | tr -d '[:space:]')" = "$(printf '%s' "$expected" | tr -d '[:space:]')" ]; then
    ok "$path = $actual"
  else
    warn "$path: mong đợi $expected nhưng đang là $actual"
    FAIL=1
  fi
done < "$PLAN_FILE"

echo
if [ "$FAIL" -eq 0 ]; then
  ok "Xong. Kiểm tra bước cuối trong session: chạy agents_list — '$AGENT' phải xuất hiện,"
  ok "và khi spawn nhớ set runtime rõ ràng: sessions_spawn({agentId: \"$AGENT\", runtime: \"acp\", ...})"
  log "Nếu vẫn không thấy: chạy 'openclaw doctor' để soi reference lệch tên."
  log "Rollback nếu cần: cp '$BACKUP' '$CONFIG_PATH' rồi restart gateway."
else
  die "Verify thất bại — config chưa đúng như mong đợi. Rollback: cp '$BACKUP' '$CONFIG_PATH' rồi restart gateway."
fi