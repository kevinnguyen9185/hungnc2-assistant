#!/usr/bin/env bash
# =============================================================================
# setup-goals.sh — Personal Goal Dashboard trên Notion
#
# Tạo 2 database dưới page "Personal Goal Dashboard" (page bạn đã tạo tay):
#   1. "Personal Tasks" — task cá nhân: Name / Status / Line / Due / Note
#   2. "Goals"          — mục tiêu lớn từng line: Name / Line / Objective / Status
# rồi seed 4 line việc: za-cs, za-standard, zclaw, zBiz.
#
# Chuẩn bị (giống setup-notion.sh — làm MỘT lần trên notion.so):
#   Page dashboard → menu ⋯ → Connections → chọn integration của bạn
#   (không share thì API không thấy page → lỗi 404).
#
# Dùng (từ thư mục chứa docker-compose.yml):
#   ./scripts/setup-goals.sh                    # dùng page id mặc định bên dưới
#   ./scripts/setup-goals.sh <link-page-khác>
#
# Idempotent: đã có id trong .env thì bỏ qua bước tạo; goal đã có thì không seed lại.
# Agent dùng qua helper:  ~/workspace/bin/personal-task  (đọc id từ file)
# =============================================================================
set -euo pipefail

CONTAINER="${CONTAINER:-hungnc2-assistant}"
ENVFILE=".env"
# Page "Personal Goal Dashboard" (2026-08-01)
DEFAULT_PAGE_ID="3af5960f92fb80a7aaeac6af150cd589"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✔\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m✘\033[0m %s\n' "$*"; }
in_ct()  { docker exec "$CONTAINER" bash -c "$*"; }
in_ct_i(){ docker exec -i "$CONTAINER" bash -c "$*"; }  # -i: cần stdin

# curl Notion trong container, JSON đưa qua stdin (token đọc từ file trong volume)
napi() { # napi <method> <path> <<< "$json"
  in_ct_i 'curl -s -X '"$1"' "https://api.notion.com/v1/'"$2"'" \
    -H "Authorization: Bearer $(cat $HOME/.openclaw/notion-token)" \
    -H "Notion-Version: 2022-06-28" -H "Content-Type: application/json" \
    --data-binary @-'
}
json_id() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("id","").replace("-",""))'; }

# --- 0. điều kiện --------------------------------------------------------------
bold "[0/5] Kiểm tra"
grep -q '^NOTION_API_KEY=..*' "$ENVFILE" || { fail "NOTION_API_KEY chưa có trong .env"; exit 1; }
docker ps --format '{{.Names}}' | grep -qx "$CONTAINER" || { fail "container chưa chạy"; exit 1; }
PAGE_ARG="${1:-$DEFAULT_PAGE_ID}"
PAGE_ID=$(printf '%s' "$PAGE_ARG" | grep -oE '[0-9a-f]{32}' | tail -1 || true)
[[ -z "$PAGE_ID" ]] && { fail "không tách được page id từ: $PAGE_ARG"; exit 1; }
ok "parent page: $PAGE_ID"

# --- 1. token → file trong volume (env của agent bị lọc) -----------------------
bold "[1/5] Token file"
if ! in_ct 'test -n "${NOTION_API_KEY:-}"'; then
  fail "Container KHÔNG có NOTION_API_KEY trong env. Chạy: docker compose up -d rồi thử lại."
  exit 1
fi
in_ct 'printf "%s" "$NOTION_API_KEY" > "$HOME/.openclaw/notion-token" && chmod 600 "$HOME/.openclaw/notion-token"'
ok "~/.openclaw/notion-token"

# --- 2. database "Personal Tasks" ----------------------------------------------
bold "[2/5] Database Personal Tasks"
if grep -q '^NOTION_PERSONAL_DB_ID=..*' "$ENVFILE"; then
  PERSONAL_DB=$(grep '^NOTION_PERSONAL_DB_ID=' "$ENVFILE" | cut -d= -f2)
  ok "đã có NOTION_PERSONAL_DB_ID=$PERSONAL_DB — bỏ qua bước tạo"
else
  RESP=$(napi POST databases <<JSON
{
  "parent": { "type": "page_id", "page_id": "$PAGE_ID" },
  "title": [{ "type": "text", "text": { "content": "Personal Tasks" } }],
  "properties": {
    "Name":   { "title": {} },
    "Status": { "select": { "options": [
      { "name": "Todo",        "color": "gray"   },
      { "name": "In progress", "color": "yellow" },
      { "name": "Done",        "color": "green"  },
      { "name": "Blocked",     "color": "red"    }
    ]}},
    "Line":   { "select": { "options": [
      { "name": "za-cs",       "color": "blue"   },
      { "name": "za-standard", "color": "purple" },
      { "name": "zclaw",       "color": "orange" },
      { "name": "zBiz",        "color": "green"  },
      { "name": "personal",    "color": "gray"   }
    ]}},
    "Due":    { "date": {} },
    "Note":   { "rich_text": {} }
  }
}
JSON
)
  PERSONAL_DB=$(printf '%s' "$RESP" | json_id)
  if [[ -z "$PERSONAL_DB" ]]; then
    fail "tạo Personal Tasks thất bại. Notion trả về:"; printf '%s' "$RESP" | head -c 500; echo
    echo "  (hay gặp: page chưa Connections với integration → 404)"; exit 1
  fi
  printf 'NOTION_PERSONAL_DB_ID=%s\n' "$PERSONAL_DB" >> "$ENVFILE"
  ok "đã tạo: $PERSONAL_DB (ghi vào .env)"
fi

# --- 3. database "Goals" --------------------------------------------------------
bold "[3/5] Database Goals"
if grep -q '^NOTION_GOALS_DB_ID=..*' "$ENVFILE"; then
  GOALS_DB=$(grep '^NOTION_GOALS_DB_ID=' "$ENVFILE" | cut -d= -f2)
  ok "đã có NOTION_GOALS_DB_ID=$GOALS_DB — bỏ qua bước tạo"
else
  RESP=$(napi POST databases <<JSON
{
  "parent": { "type": "page_id", "page_id": "$PAGE_ID" },
  "title": [{ "type": "text", "text": { "content": "Goals" } }],
  "properties": {
    "Name":      { "title": {} },
    "Line":      { "select": { "options": [
      { "name": "za-cs",       "color": "blue"   },
      { "name": "za-standard", "color": "purple" },
      { "name": "zclaw",       "color": "orange" },
      { "name": "zBiz",        "color": "green"  }
    ]}},
    "Objective": { "rich_text": {} },
    "Status":    { "select": { "options": [
      { "name": "Active", "color": "green"  },
      { "name": "Paused", "color": "yellow" },
      { "name": "Done",   "color": "blue"   }
    ]}}
  }
}
JSON
)
  GOALS_DB=$(printf '%s' "$RESP" | json_id)
  if [[ -z "$GOALS_DB" ]]; then
    fail "tạo Goals thất bại. Notion trả về:"; printf '%s' "$RESP" | head -c 500; echo; exit 1
  fi
  printf 'NOTION_GOALS_DB_ID=%s\n' "$GOALS_DB" >> "$ENVFILE"
  ok "đã tạo: $GOALS_DB (ghi vào .env)"
fi

# --- 4. id → file cho agent -----------------------------------------------------
bold "[4/5] DB id vào file bền"
in_ct "printf '%s' '$PERSONAL_DB' > \"\$HOME/.openclaw/notion-personal-db-id\" && chmod 600 \"\$HOME/.openclaw/notion-personal-db-id\""
in_ct "printf '%s' '$GOALS_DB'    > \"\$HOME/.openclaw/notion-goals-db-id\"    && chmod 600 \"\$HOME/.openclaw/notion-goals-db-id\""
ok "~/.openclaw/notion-personal-db-id, ~/.openclaw/notion-goals-db-id"

# --- 5. seed 4 line việc (idempotent theo Line) ---------------------------------
bold "[5/5] Seed goals"
seed_goal() { # seed_goal <line> <name> <objective>
  local line="$1" name="$2" obj="$3"
  local n
  n=$(napi POST "databases/$GOALS_DB/query" <<JSON | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("results",[])))'
{ "filter": { "property": "Line", "select": { "equals": "$line" } } }
JSON
)
  if [[ "$n" != "0" ]]; then
    printf '  · %s (đã có, giữ nguyên)\n' "$line"
    return
  fi
  napi POST pages >/dev/null <<JSON
{
  "parent": { "database_id": "$GOALS_DB" },
  "properties": {
    "Name":      { "title": [{ "text": { "content": "$name" } }] },
    "Line":      { "select": { "name": "$line" } },
    "Status":    { "select": { "name": "Active" } },
    "Objective": { "rich_text": [{ "text": { "content": "$obj" } }] }
  }
}
JSON
  ok "seed: $line"
}
seed_goal "za-cs"       "Chatbot CS"        "Tạo chatbot CS cho Zalo (hybrid rule + LLM)"
seed_goal "za-standard" "Chuẩn hoá SDLC"    "Chuẩn hoá quy trình phát triển phần mềm (SDLC) của Zalo — giai đoạn 1: unit test trong CI/CD"
seed_goal "zclaw"       "Cập nhật zclaw"    "Cập nhật zclaw với các bản cập nhật mới"
seed_goal "zBiz"        "Assistant zBiz"    "Xây dựng assistant cùng với zBiz"

echo
bold "Xong. Test nhanh:"
echo "  docker exec $CONTAINER bash -c '~/workspace/bin/personal-task report'"
echo "  docker exec $CONTAINER bash -c '~/workspace/bin/personal-task create \"thử task\" personal $(date +%F)'"
