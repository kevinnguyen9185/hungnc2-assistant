#!/usr/bin/env bash
# =============================================================================
# setup-notion.sh — tạo database "Assistant Tasks" trên Notion + cấu hình agent
#
# Chuẩn bị (làm MỘT lần trên notion.so):
#   1. Tạo một page trống, ví dụ "Assistant Board".
#   2. Page đó → menu ⋯ → Connections → chọn integration của bạn
#      (không share thì API không thấy page → lỗi 404).
#   3. Copy link page rồi chạy:
#        ./scripts/setup-notion.sh <link-page-hoặc-page-id>
#
# Script sẽ:
#   1. lưu NOTION_API_KEY (.env) vào file ~/.openclaw/notion-token trong
#      container — shell của agent bị LỌC env nên phải đọc token từ file
#   2. gọi API tạo database với schema: Name / Status / Agent / Project / Note
#   3. ghi NOTION_DB_ID vào .env và ~/.openclaw/notion-db-id
#
# Idempotent: đã có NOTION_DB_ID trong .env thì chỉ đồng bộ lại token file.
# =============================================================================
set -euo pipefail

CONTAINER="${CONTAINER:-hungnc2-assistant}"
ENVFILE=".env"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✔\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m✘\033[0m %s\n' "$*"; }
in_ct() { docker exec "$CONTAINER" bash -c "$*"; }

# --- 0. điều kiện ---------------------------------------------------------------
bold "[0/3] Kiểm tra"
grep -q '^NOTION_API_KEY=..*' "$ENVFILE" || { fail "NOTION_API_KEY chưa có trong .env"; exit 1; }
docker ps --format '{{.Names}}' | grep -qx "$CONTAINER" || { fail "container chưa chạy"; exit 1; }
ok "ổn"

# --- 1. token → file trong volume (env của agent bị lọc) --------------------------
bold "[1/3] Lưu token vào file bền"
# CHẶN SỚM: container cũ (chưa recreate sau khi thêm key vào .env) sẽ có
# NOTION_API_KEY rỗng → ghi file 0 byte → Notion trả 401 khó hiểu.
if ! in_ct 'test -n "${NOTION_API_KEY:-}"'; then
  fail "Container KHÔNG có NOTION_API_KEY trong env."
  echo "     .env sửa rồi nhưng container còn env cũ. Chạy:  docker compose up -d"
  echo "     (docker restart KHÔNG nạp lại .env!)  Rồi chạy lại script này."
  exit 1
fi
in_ct 'printf "%s" "$NOTION_API_KEY" > "$HOME/.openclaw/notion-token" && chmod 600 "$HOME/.openclaw/notion-token"'
ok "~/.openclaw/notion-token (chmod 600)"

# --- 2. tạo database (nếu chưa có) --------------------------------------------------
bold "[2/3] Database Notion"
if grep -q '^NOTION_DB_ID=..*' "$ENVFILE"; then
  DB_ID=$(grep '^NOTION_DB_ID=' "$ENVFILE" | cut -d= -f2)
  ok "đã có NOTION_DB_ID=$DB_ID — bỏ qua bước tạo"
else
  PAGE_ARG="${1:-}"
  [[ -z "$PAGE_ARG" ]] && { fail "cần link page: ./scripts/setup-notion.sh <link>"; exit 1; }
  # lấy 32 ký tự hex cuối của link làm page id
  PAGE_ID=$(printf '%s' "$PAGE_ARG" | grep -oE '[0-9a-f]{32}' | tail -1 || true)
  [[ -z "$PAGE_ID" ]] && { fail "không tách được page id từ: $PAGE_ARG"; exit 1; }
  ok "parent page: $PAGE_ID"

  RESP=$(in_ct 'curl -s -X POST https://api.notion.com/v1/databases \
    -H "Authorization: Bearer $(cat $HOME/.openclaw/notion-token)" \
    -H "Notion-Version: 2022-06-28" -H "Content-Type: application/json" \
    -d @- <<JSON
{
  "parent": { "type": "page_id", "page_id": "'"$PAGE_ID"'" },
  "title": [{ "type": "text", "text": { "content": "Assistant Tasks" } }],
  "properties": {
    "Name":    { "title": {} },
    "Status":  { "select": { "options": [
      { "name": "Todo",        "color": "gray"   },
      { "name": "In progress", "color": "yellow" },
      { "name": "Done",        "color": "green"  },
      { "name": "Blocked",     "color": "red"    }
    ]}},
    "Agent":   { "select": { "options": [
      { "name": "claude", "color": "orange" },
      { "name": "codex",  "color": "green"  },
      { "name": "zalo",   "color": "blue"   }
    ]}},
    "Project": { "select": {} },
    "Note":    { "rich_text": {} }
  }
}
JSON')
  DB_ID=$(printf '%s' "$RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id','').replace('-',''))" 2>/dev/null || true)
  if [[ -z "$DB_ID" ]]; then
    fail "tạo database thất bại. Notion trả về:"
    printf '%s' "$RESP" | head -c 500; echo
    echo "  (hay gặp: page chưa Connections với integration → 404)"
    exit 1
  fi
  printf 'NOTION_DB_ID=%s\n' "$DB_ID" >> "$ENVFILE"
  ok "đã tạo database: $DB_ID (đã ghi vào .env)"
fi

# --- 3. db id → file cho agent -----------------------------------------------------
bold "[3/3] DB id vào file bền"
in_ct "printf '%s' '$DB_ID' > \"\$HOME/.openclaw/notion-db-id\" && chmod 600 \"\$HOME/.openclaw/notion-db-id\""
ok "~/.openclaw/notion-db-id"

echo
bold "Xong. Test nhanh (tạo 1 task thử):"
echo '  docker exec '"$CONTAINER"' bash -c '"'"'curl -s -X POST https://api.notion.com/v1/pages \
    -H "Authorization: Bearer $(cat ~/.openclaw/notion-token)" \
    -H "Notion-Version: 2022-06-28" -H "Content-Type: application/json" \
    -d "{\"parent\":{\"database_id\":\"$(cat ~/.openclaw/notion-db-id)\"},\"properties\":{\"Name\":{\"title\":[{\"text\":{\"content\":\"test từ CLI\"}}]},\"Status\":{\"select\":{\"name\":\"Done\"}},\"Agent\":{\"select\":{\"name\":\"claude\"}}}}" | head -c 200'"'"''