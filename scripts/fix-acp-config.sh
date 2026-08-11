#!/usr/bin/env bash
# =============================================================================
# fix-acp-config.sh — cho phép spawn ACP agent (mặc định: codex) qua
# sessions_spawn, viết ĐÚNG cho repo hungnc2-assistant (OpenClaw trong Docker).
#
# Vấn đề nó sửa: agents_list chỉ trả về "claude", sessions_spawn(agentId=
# "codex") bị chặn với "not allowed (allowed: claude)". Nguyên nhân: config
# chưa có agents.defaults.subagents.allowAgents nên gateway rơi về mặc định
# hẹp. Fix = TẠO key đó với đủ các agent đã khai báo trong agents.list.
#
# Khớp với thực tế của repo này (khác các bản generic trước):
#   * Config dùng schema agents.list (không phải agents.entries)
#   * `openclaw config set` của bản đang cài KHÔNG ghi được array
#     → patch bằng jq trong container, giống setup-acp.sh (jq có sẵn, Dockerfile)
#   * `bash -c` chứ KHÔNG PHẢI `bash -lc` — login shell đọc lại /etc/profile,
#     reset PATH và mất ~/.npm-global/bin nơi chứa openclaw (ghi chú Dockerfile)
#   * Restart = docker restart container (gateway là process chính của container)
#   * Verify SAU restart — gateway ghi đè openclaw.json lúc boot, phải chắc
#     key mình thêm sống sót qua lần ghi đó
#
# Cách dùng (trên HOST, từ thư mục repo — không cần COMPOSE_DIR gì cả):
#   DRY_RUN=1 ./scripts/fix-acp-config.sh      # xem diff, KHÔNG sửa gì
#   ./scripts/fix-acp-config.sh                # áp dụng cho "codex"
#   ./scripts/fix-acp-config.sh <agent-khác>   # agent khác (phải có trong agents.list)
#   CONTAINER=tên-khác ...                     # nếu đổi container_name trong compose
#
# Idempotent: chạy lại bao nhiêu lần cũng được, không duplicate, không đổi gì
# thì không restart.
# =============================================================================
set -euo pipefail

AGENT="${1:-codex}"
CONTAINER="${CONTAINER:-hungnc2-assistant}"
DRY_RUN="${DRY_RUN:-0}"
SKIP_RESTART="${SKIP_RESTART:-0}"
CFG='$HOME/.openclaw/openclaw.json'   # nở ra BÊN TRONG container (user openclaw)

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✔\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m⚠\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m✘\033[0m %s\n' "$*"; }
die()  { fail "$*"; exit 1; }

# bash -c, KHÔNG -lc (xem ghi chú đầu file)
in_ct() { docker exec "$CONTAINER" bash -c "$*"; }

# --- 0. container đang chạy ổn định? -----------------------------------------
bold "[0/4] Kiểm tra container '$CONTAINER'"
command -v docker >/dev/null 2>&1 || die "Không có docker trên host."
docker ps --format '{{.Names}}' | grep -qx "$CONTAINER" \
  || die "Container chưa chạy. Khởi động trước:  docker compose up -d --build"
state=$(docker inspect -f '{{.State.Status}}/{{.State.Restarting}}' "$CONTAINER")
[[ "$state" == "running/false" ]] \
  || die "Container không ổn định (state=$state). Xem:  docker logs --tail 50 $CONTAINER"
in_ct "command -v jq >/dev/null" || die "Không có jq trong container (Dockerfile chuẩn phải có)."
in_ct "test -f $CFG" || die "Không thấy openclaw.json trong container ($CFG)."
ok "container chạy ổn, jq + config sẵn sàng"

# --- 1. tính config mới bằng jq (trong container, cạnh file gốc) --------------
bold "[1/4] Tính thay đổi cho agent '$AGENT'"

# agent phải được khai báo trong agents.list trước đã
in_ct "jq -e --arg a '$AGENT' '.agents.list[]? | select(.id==\$a)' $CFG >/dev/null" \
  || die "'$AGENT' không có trong agents.list — chạy ./scripts/setup-acp.sh $AGENT trước."

# Chương trình jq, nạp vào container qua stdin để né quoting nhiều tầng.
# Logic:
#   - allowAgents đã có "*" hoặc có agent rồi -> giữ nguyên
#   - allowAgents có nhưng thiếu agent       -> thêm vào cuối
#   - allowAgents CHƯA CÓ (case thật của repo này) -> TẠO MỚI với toàn bộ
#     id trong agents.list (allowlist tường minh, không dùng "*")
#   - per-agent override trong từng item agents.list (nếu có) -> thêm tương tự
#   - acp.allowedAgents (nếu có set) -> thêm tương tự; chưa set thì để yên
JQ_PROG='
def add_missing($a): if (index("*") or index($a)) then . else . + [$a] end;
([.agents.list[]?.id] // []) as $ids
| .agents.defaults.subagents.allowAgents =
    ((.agents.defaults.subagents.allowAgents // $ids) | add_missing($agent))
| .agents.list = [ (.agents.list // [])[]
    | if (.subagents.allowAgents? != null)
      then .subagents.allowAgents |= add_missing($agent) else . end ]
| if (.acp.allowedAgents? != null)
  then .acp.allowedAgents |= add_missing($agent) else . end
'
printf '%s' "$JQ_PROG" | docker exec -i "$CONTAINER" bash -c 'cat > /tmp/fix-acp.jq'

# ghi bản mới NGAY CẠNH file gốc (cùng filesystem -> mv là atomic)
in_ct "jq --arg agent '$AGENT' -f /tmp/fix-acp.jq $CFG > $CFG.new" \
  || die "jq chạy lỗi — config có gì đó bất thường, xem: docker exec $CONTAINER cat $CFG"

if in_ct "cmp -s $CFG $CFG.new"; then
  in_ct "rm -f $CFG.new"
  ok "Config đã cho phép '$AGENT' sẵn — không sửa gì, không restart."
  exit 0
fi

echo "  Thay đổi sẽ áp dụng:"
in_ct "diff <(jq -S . $CFG) <(jq -S . $CFG.new)" || true

if [[ "$DRY_RUN" == "1" ]]; then
  in_ct "rm -f $CFG.new"
  bold "(dry-run) Chưa sửa gì cả. Chạy lại không có DRY_RUN=1 để áp dụng."
  exit 0
fi

# --- 2. backup + áp dụng -------------------------------------------------------
bold "[2/4] Backup + ghi config"
TS="$(date +%Y%m%d-%H%M%S)"
in_ct "cp -p $CFG $CFG.bak.$TS"
ok "backup: data/openclaw/openclaw.json.bak.$TS (nằm trên host, trong volume mount)"
in_ct "mv $CFG.new $CFG"
ok "đã ghi config mới"

# --- 3. restart gateway (container) --------------------------------------------
bold "[3/4] Restart gateway"
if [[ "$SKIP_RESTART" == "1" ]]; then
  warn "SKIP_RESTART=1 — nhớ 'docker restart $CONTAINER' để config có hiệu lực."
else
  docker restart "$CONTAINER" >/dev/null
  # đợi gateway thật sự sẵn sàng (dùng đúng probe /healthz của healthcheck)
  ready=0
  for _ in $(seq 1 45); do
    if in_ct "node -e \"fetch('http://127.0.0.1:18789/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))\"" 2>/dev/null; then
      ready=1; break
    fi
    sleep 2
  done
  [[ "$ready" == "1" ]] && ok "gateway đã lên lại" \
    || warn "90s mà /healthz chưa OK — xem: docker logs --tail 50 $CONTAINER"
fi

# --- 4. verify SAU restart (gateway ghi đè config lúc boot) ---------------------
bold "[4/4] Verify"
if in_ct "jq -e --arg a '$AGENT' '(.agents.defaults.subagents.allowAgents // []) | (index(\$a) != null) or (index(\"*\") != null)' $CFG >/dev/null"; then
  ok "agents.defaults.subagents.allowAgents có '$AGENT' và sống sót qua restart"
  echo
  bold "Xong. Kiểm tra từ chat/session:"
  echo "  * agents_list          → phải thấy '$AGENT'"
  echo "  * sessions_spawn(agentId=\"$AGENT\")  → hết bị 'not allowed'"
  echo "  * hoặc từ Telegram:    /acp spawn $AGENT"
  echo "  Rollback nếu cần: cp data/openclaw/openclaw.json.bak.$TS data/openclaw/openclaw.json && docker restart $CONTAINER"
else
  fail "Gateway đã ghi đè mất key sau restart (schema version không nhận?)."
  echo "  Xem schema bản đang cài:  docker exec $CONTAINER openclaw doctor"
  echo "  Rollback: cp data/openclaw/openclaw.json.bak.$TS data/openclaw/openclaw.json && docker restart $CONTAINER"
  exit 1
fi
