#!/usr/bin/env bash
# =============================================================================
# set-model.sh — đổi model mặc định của gateway (desk Zalo/native agent)
# mà KHÔNG phải chạy lại toàn bộ setup-acp.sh (đỡ 30s probe login + các bước thừa).
#
# Lưu ý phạm vi: model này chỉ ảnh hưởng desk dùng OpenRouter (zalo-desk).
# claude-desk / codex-desk chạy bằng subscription qua ACP — đổi model ở đây
# KHÔNG làm hai desk đó nhanh lên.
#
# Cách dùng (trên HOST, từ thư mục repo):
#   DRY_RUN=1 ./scripts/set-model.sh                 # xem sẽ đổi gì, không sửa
#   ./scripts/set-model.sh                           # đổi sang mặc định mới:
#                                                    #   openrouter/~deepseek/deepseek-v4-flash-latest
#   ./scripts/set-model.sh openrouter/deepseek/deepseek-v4-flash-0731   # pin bản cụ thể
#
# Về id có dấu "~": trên OpenRouter, "~deepseek/deepseek-v4-flash-latest" là
# ALIAS — luôn trỏ tới snapshot Flash mới nhất (tự nâng cấp khi DeepSeek ra bản
# mới). Muốn kết quả ổn định tuyệt đối thì pin bản có ngày (vd ...-0731).
#
# Idempotent: model đã đúng thì không đụng gì, không restart.
# =============================================================================
set -euo pipefail

MODEL_REF="${1:-openrouter/~deepseek/deepseek-v4-flash-latest}"
CONTAINER="${CONTAINER:-hungnc2-assistant}"
DRY_RUN="${DRY_RUN:-0}"
SKIP_RESTART="${SKIP_RESTART:-0}"
CFG='$HOME/.openclaw/openclaw.json'   # nở ra BÊN TRONG container

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✔\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m⚠\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m✘\033[0m %s\n' "$*"; }
die()  { fail "$*"; exit 1; }

# bash -c, KHÔNG -lc (login shell reset PATH, mất ~/.npm-global/bin)
in_ct() { docker exec "$CONTAINER" bash -c "$*"; }

# --- 0. container ổn định? -----------------------------------------------------
bold "[0/4] Kiểm tra container '$CONTAINER'"
command -v docker >/dev/null 2>&1 || die "Không có docker trên host."
docker ps --format '{{.Names}}' | grep -qx "$CONTAINER" \
  || die "Container chưa chạy:  docker compose up -d --build"
state=$(docker inspect -f '{{.State.Status}}/{{.State.Restarting}}' "$CONTAINER")
[[ "$state" == "running/false" ]] \
  || die "Container không ổn định (state=$state):  docker logs --tail 50 $CONTAINER"
in_ct "test -f $CFG" || die "Không thấy openclaw.json trong container."
ok "container chạy ổn"

# --- 1. model hiện tại + kiểm tra id mới ----------------------------------------
bold "[1/4] Model hiện tại → mới"
current="$(in_ct "jq -r '.agents.defaults.model.primary // \"\"' $CFG")"
if [[ "$current" == "$MODEL_REF" ]]; then
  ok "Model đã là '$MODEL_REF' — không đổi gì, không restart."
  exit 0
fi
echo "  hiện tại : ${current:-<chưa set>}"
echo "  đổi thành: $MODEL_REF"

# Best-effort: xác nhận id tồn tại trên catalog OpenRouter (curl từ container,
# nơi đã có CA công ty). Không xác nhận được (mạng/proxy) thì chỉ cảnh báo —
# bước verify cuối vẫn bắt được id sai vì gateway sẽ từ chối.
if [[ "$MODEL_REF" == openrouter/* ]]; then
  orid="${MODEL_REF#openrouter/}"
  if in_ct "curl -fsS --max-time 15 https://openrouter.ai/api/v1/models | jq -e --arg id '$orid' '.data[]? | select(.id==\$id)' >/dev/null" 2>/dev/null; then
    ok "id '$orid' có trên catalog OpenRouter"
  else
    warn "không xác nhận được '$orid' trên OpenRouter (mạng? id sai?) — vẫn tiếp tục, xem verify ở bước cuối"
  fi
fi

if [[ "$DRY_RUN" == "1" ]]; then
  bold "(dry-run) Chưa sửa gì cả. Chạy lại không có DRY_RUN=1 để áp dụng."
  exit 0
fi

# --- 2. backup + đổi model -------------------------------------------------------
bold "[2/4] Backup + đổi model"
TS="$(date +%Y%m%d-%H%M%S)"
in_ct "cp -p $CFG $CFG.bak.$TS"
ok "backup: data/openclaw/openclaw.json.bak.$TS"

# Đường chính: CLI (đúng triết lý repo — không tự tay viết openclaw.json).
# Retry vì gateway có thể ghi đè config cùng lúc (ConfigMutationConflictError).
set_ok=0
for _ in 1 2 3 4 5; do
  if in_ct "openclaw models set '$MODEL_REF'" 2>/dev/null; then set_ok=1; break; fi
  sleep 3
done
if [[ "$set_ok" == "1" ]]; then
  ok "openclaw models set '$MODEL_REF'"
else
  # Fallback: patch jq đúng shape config hiện tại (primary + entry trong models)
  warn "'openclaw models set' thất bại sau 5 lần — patch trực tiếp bằng jq"
  in_ct "jq --arg m '$MODEL_REF' \
    '.agents.defaults.model.primary = \$m | .agents.defaults.models[\$m] //= {}' \
    $CFG > $CFG.new && mv $CFG.new $CFG"
  ok "đã patch config bằng jq"
fi

# --- 3. restart gateway -----------------------------------------------------------
bold "[3/4] Restart gateway"
if [[ "$SKIP_RESTART" == "1" ]]; then
  warn "SKIP_RESTART=1 — nhớ 'docker restart $CONTAINER' để model mới có hiệu lực."
else
  docker restart "$CONTAINER" >/dev/null
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

# --- 4. verify SAU restart ---------------------------------------------------------
bold "[4/4] Verify"
after="$(in_ct "jq -r '.agents.defaults.model.primary // \"\"' $CFG")"
if [[ "$after" == "$MODEL_REF" ]]; then
  ok "model.primary = $after (sống sót qua restart)"
  echo
  bold "Xong. Test thật: nhắn desk Zalo một câu và xem tốc độ trả lời."
  echo "  Entry model cũ còn nằm trong agents.defaults.models — vô hại, gateway bỏ qua."
  echo "  Rollback: cp data/openclaw/openclaw.json.bak.$TS data/openclaw/openclaw.json && docker restart $CONTAINER"
else
  fail "model.primary đang là '$after', không phải '$MODEL_REF' — gateway từ chối hoặc ghi đè."
  echo "  Soi thêm:  docker exec $CONTAINER openclaw models list"
  echo "  Rollback:  cp data/openclaw/openclaw.json.bak.$TS data/openclaw/openclaw.json && docker restart $CONTAINER"
  exit 1
fi
