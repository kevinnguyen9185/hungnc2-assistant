#!/usr/bin/env bash
# =============================================================================
# setup-reminder.sh — cron OpenClaw: 9h sáng hằng ngày (Asia/Ho_Chi_Minh)
#
# Job "morning-review" chạy isolated agent turn:
#   - đọc task cá nhân từ Notion qua ~/workspace/bin/personal-task
#   - nhắn Telegram cho chủ nhân: task hôm nay + quá hạn
#   - riêng thứ Hai: thêm tổng quan tuần + tiến độ các line việc (report)
#
# Chạy SAU setup-goals.sh (cần notion-personal-db-id / notion-goals-db-id).
#
# Dùng (từ thư mục chứa docker-compose.yml):
#   ./scripts/setup-reminder.sh
#
# Idempotent: job cũ cùng tên bị xoá rồi tạo lại (nên sửa prompt ở đây rồi
# chạy lại script là cách chuẩn để cập nhật).
# =============================================================================
set -euo pipefail

CONTAINER="${CONTAINER:-hungnc2-assistant}"
JOB_NAME="morning-review"
CRON_EXPR="0 9 * * *"
TZ_NAME="Asia/Ho_Chi_Minh"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✔\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m⚠\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m✘\033[0m %s\n' "$*"; }
in_ct() { docker exec "$CONTAINER" bash -c "$*"; }

# --- 0. điều kiện ---------------------------------------------------------------
bold "[0/3] Kiểm tra"
docker ps --format '{{.Names}}' | grep -qx "$CONTAINER" || { fail "container chưa chạy"; exit 1; }
in_ct 'test -f "$HOME/.openclaw/notion-personal-db-id"' \
  || { fail "chưa có notion-personal-db-id — chạy ./scripts/setup-goals.sh trước"; exit 1; }
# Telegram id chủ nhân: lấy từ commands.ownerAllowFrom trong openclaw.json
OWNER=$(python3 -c '
import json
c = json.load(open("data/openclaw/openclaw.json"))
ids = [x.split(":",1)[1] for x in c.get("commands",{}).get("ownerAllowFrom",[]) if x.startswith("telegram:")]
print(ids[0] if ids else "")')
[[ -z "$OWNER" ]] && { fail "không tìm thấy telegram owner trong openclaw.json (commands.ownerAllowFrom)"; exit 1; }
ok "owner: telegram:$OWNER"

# --- 1. xoá job cũ cùng tên (idempotent) ------------------------------------------
bold "[1/3] Dọn job cũ '$JOB_NAME'"
OLD_IDS=$(in_ct 'openclaw cron list --json 2>/dev/null' | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
jobs = d.get("jobs", d) if isinstance(d, dict) else d
for j in jobs if isinstance(jobs, list) else []:
    if isinstance(j, dict) and j.get("name") == "'"$JOB_NAME"'":
        print(j.get("id", ""))' || true)
if [[ -n "$OLD_IDS" ]]; then
  for id in $OLD_IDS; do
    in_ct "openclaw cron remove '$id'" && ok "đã xoá job cũ: $id"
  done
else
  ok "không có job cũ (hoặc CLI không hỗ trợ --json — kiểm tra tay: openclaw cron list)"
fi

# --- 2. tạo job -------------------------------------------------------------------
bold "[2/3] Tạo cron '$JOB_NAME' ($CRON_EXPR $TZ_NAME)"
PROMPT='Nhắc nhở 9h sáng (job tự động, trả lời bằng tiếng Việt). Làm đúng các bước sau bằng exec:
(1) date "+%A %F"
(2) ~/workspace/bin/personal-task list today
(3) ~/workspace/bin/personal-task list overdue
(4) CHỈ KHI bước 1 cho thấy hôm nay là Monday: chạy thêm ~/workspace/bin/personal-task list week và ~/workspace/bin/personal-task report
Rồi soạn MỘT tin nhắn ngắn, dễ đọc trên điện thoại:
- Task đến hạn hôm nay (nếu có)
- Task quá hạn (nếu có, kèm số ngày trễ)
- Thứ Hai: thêm mục "Tuần này" và "Tiến độ các line" từ output report
Không bịa task không có trong output. Nếu hoàn toàn không có task đến hạn/quá hạn thì nhắn đúng một câu: "Hôm nay không có task đến hạn."'

in_ct "openclaw cron add \
  --name '$JOB_NAME' \
  --cron '$CRON_EXPR' \
  --tz '$TZ_NAME' \
  --exact \
  --session isolated \
  --message $(printf '%q' "$PROMPT") \
  --announce --channel telegram --to '$OWNER'"
ok "đã tạo job"

# --- 3. kiểm tra ------------------------------------------------------------------
bold "[3/3] Kiểm tra"
in_ct 'openclaw cron list' | sed 's/^/  /'
echo
bold "Chạy thử ngay (không đợi 9h sáng):"
echo "  docker exec $CONTAINER bash -c 'openclaw cron list --json' | python3 -c 'import json,sys; [print(j[\"id\"],j[\"name\"]) for j in json.load(sys.stdin).get(\"jobs\",[])]'"
echo "  docker exec $CONTAINER bash -c 'openclaw cron run <jobId> --wait'"
