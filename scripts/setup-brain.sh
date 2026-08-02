#!/usr/bin/env bash
# =============================================================================
# setup-brain.sh — dựng / đồng bộ "brain" (bộ nhớ dài hạn của assistant)
#
# brain = repo git riêng, chứa markdown thuần, nằm ở ~/workspace/brain.
# Model không nhớ gì giữa các phiên; cái gì cần nhớ lâu thì nằm ở đây.
#
# Script làm gì (idempotent — chạy lại bao nhiêu lần cũng an toàn):
#   1. tạo cấu trúc thư mục + các file khung nếu THIẾU (không ghi đè file có sẵn)
#   2. tạo file decisions/<tháng hiện tại>.md nếu chưa có
#   3. git init + commit nếu chưa phải repo
#   4. tạo repo private trên GitHub và push nếu chưa có remote
#   5. quét bảo đảm không có secret lọt vào vault
#
# Cách dùng (từ thư mục chứa docker-compose.yml):
#   ./scripts/setup-brain.sh                 # dựng + push (org my-agents-090185)
#   ./scripts/setup-brain.sh --no-push       # chỉ dựng, không đụng GitHub
#   REPO_NAME=my-brain ./scripts/setup-brain.sh
#   REPO_OWNER= ./scripts/setup-brain.sh     # để trống = tạo dưới tài khoản cá nhân
#
# Chạy MỖI THÁNG cũng tốt: nó tự tạo file decisions của tháng mới.
# =============================================================================
set -euo pipefail

CONTAINER="${CONTAINER:-hungnc2-assistant}"
BRAIN="/home/openclaw/workspace/brain"
REPO_NAME="${REPO_NAME:-brain}"
# Org chứa các repo của assistant (cùng chỗ với xyz). Để trống → dùng tài
# khoản cá nhân lấy từ `gh api user`.
REPO_OWNER="${REPO_OWNER:-my-agents-090185}"
GIT_NAME="${GIT_NAME:-Assistant (setup)}"
GIT_EMAIL="${GIT_EMAIL:-hungnc2@vng.com.vn}"
PUSH=1
[[ "${1:-}" == "--no-push" ]] && PUSH=0

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✔\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m⚠\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m✘\033[0m %s\n' "$*"; }

in_ct() { docker exec "$CONTAINER" bash -c "$*"; }

# ghi file chỉ khi CHƯA tồn tại — không bao giờ đè nội dung bạn/agent đã viết
seed() { # seed <đường dẫn tương đối> <nội dung>
  local rel="$1" body="$2"
  if in_ct "test -e '$BRAIN/$rel'"; then
    printf '  · %s (đã có, giữ nguyên)\n' "$rel"
  else
    in_ct "mkdir -p \"\$(dirname '$BRAIN/$rel')\" && cat > '$BRAIN/$rel' <<'SEED_EOF'
$body
SEED_EOF"
    ok "$rel (tạo mới)"
  fi
}

# --- 0. container ------------------------------------------------------------
bold "[0/5] Container '$CONTAINER'"
if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  fail "Container chưa chạy. Chạy trước:  docker compose up -d"
  exit 1
fi
ok "đang chạy"

# --- 1. cấu trúc + file khung -------------------------------------------------
bold "[1/5] Cấu trúc vault"
in_ct "mkdir -p '$BRAIN'/{decisions,projects,infra}"

seed "README.md" '# brain — bộ nhớ dài hạn của assistant

Đây là **bộ nhớ thật** của trợ lý. Model không nhớ gì giữa các phiên; cái gì
muốn nhớ lâu thì phải nằm trong thư mục này và được commit.

Chỉ là markdown thuần + git. Mở bằng Obsidian, VS Code, hay `cat` đều được.

## Cấu trúc

| Thư mục / file | Chứa gì |
|---|---|
| `00-inbox.md` | Ghi nhanh, chưa phân loại. Dọn định kỳ. |
| `user.md` | Thông tin & sở thích của người dùng |
| `decisions/YYYY-MM.md` | Log quyết định theo tháng |
| `projects/<slug>.md` | Trạng thái từng dự án |
| `infra/*.md` | Server, URL, quy trình, bài học vận hành |
| `conventions.md` | Quy ước làm việc chung |

File nhỏ, chia theo tháng/dự án là CỐ Ý: hai máy cùng ghi thì ít xung đột merge.

## Luật ghi (agent bắt buộc tuân theo)

1. `git pull --rebase` TRƯỚC khi ghi. Lỗi thì dừng và báo người dùng.
2. Ghi vào đúng file theo bảng trên; không rõ thì `00-inbox.md`.
3. Mỗi dòng bắt đầu bằng ngày: `- 2026-07-31: <sự việc>`.
4. Commit + push NGAY sau khi ghi, dùng danh tính worker (xem `conventions.md`).
5. **KHÔNG BAO GIỜ ghi secret**: token, mật khẩu, API key. Chỉ ghi TÊN biến.
6. Ghi sự thật lâu bền, không ghi nhật ký hội thoại. Tự hỏi: "3 tháng nữa
   điều này còn hữu ích không?"

## Luật đọc
Đọc `user.md` + `conventions.md` + file dự án liên quan trước khi làm việc.'

seed "user.md" '# Người dùng

- Múi giờ: Asia/Ho_Chi_Minh. Ngôn ngữ: tiếng Việt, tiếng Anh.
- Trả lời **ngắn, hợp đọc trên điện thoại**. Giải thích đơn giản.
- Trả lời bằng đúng ngôn ngữ người dùng đang viết.'

seed "conventions.md" '# Quy ước làm việc chung (mọi desk)

## Danh tính commit
Dùng cờ `-c` cho từng lệnh; **không bao giờ** `git config` trong repo:

```bash
git -c user.name="Assistant (Claude Code)" -c user.email="<email>" commit -m "..."
git -c user.name="Assistant (Codex)"       -c user.email="<email>" commit -m "..."
git -c user.name="Assistant (Zalo desk)"   -c user.email="<email>" commit -m "..."
```

## Git sync
GitHub là nguồn chân lý: `git pull --rebase` trước khi làm, commit + push sau
mỗi task. Dự án mới: `gh repo create <slug> --private --source . --push`.

## An toàn
- Không deploy production. Chỉ staging.
- Lệnh phá hủy: chỉ làm khi tin nhắn người dùng có chữ CONFIRM.
- Không in secret ra chat, không ghi secret vào brain.'

seed "00-inbox.md" '# Inbox — ghi nhanh, chưa phân loại

Chưa chắc thuộc file nào thì ghi vào đây. Dọn định kỳ: chuyển sang
`decisions/`, `projects/`, `infra/` rồi xóa khỏi đây.'

seed ".gitignore" '# Obsidian: giữ config chung, bỏ trạng thái cửa sổ (đổi liên tục)
.obsidian/workspace*
.obsidian/cache
.trash/

# Chặn secret lọt vào vault
.env
.env.*
*.key
*.pem
*credentials*
*token*
id_rsa*

.DS_Store'

# --- 2. file quyết định của tháng hiện tại ------------------------------------
bold "[2/5] File quyết định tháng này"
MONTH="$(date +%Y-%m)"
seed "decisions/$MONTH.md" "# Quyết định — $MONTH"

# --- 3. git repo ---------------------------------------------------------------
bold "[3/5] Git repo"
if in_ct "test -d '$BRAIN/.git'"; then
  ok "đã là git repo"
else
  in_ct "cd '$BRAIN' && git init -q ."
  ok "git init"
fi
# commit mọi thay đổi đang chờ (nếu có)
if in_ct "cd '$BRAIN' && test -n \"\$(git status --porcelain)\""; then
  in_ct "cd '$BRAIN' && git add -A && git -c user.name='$GIT_NAME' -c user.email='$GIT_EMAIL' commit -qm 'brain: cập nhật cấu trúc ($(date +%F))'"
  ok "đã commit thay đổi"
else
  ok "không có gì để commit"
fi

# --- 4. remote GitHub ----------------------------------------------------------
bold "[4/5] GitHub remote"
if [[ "$PUSH" -eq 0 ]]; then
  warn "--no-push: bỏ qua bước GitHub"
elif in_ct "cd '$BRAIN' && git remote get-url origin >/dev/null 2>&1"; then
  url=$(in_ct "cd '$BRAIN' && git remote get-url origin" | tr -d '\r\n')
  me=$(in_ct "gh api user --jq .login 2>/dev/null" || true)
  me="$(printf '%s' "$me" | tr -d '\r\n ')"
  owner="${REPO_OWNER:-$me}"
  want="https://github.com/$owner/$REPO_NAME.git"
  if [[ "$url" != "$want" ]]; then
    warn "remote đang trỏ SAI chỗ:"
    echo "     hiện tại: $url"
    echo "     mong muốn: $want"
    # repo đích đã tồn tại chưa? chưa thì tạo (private, trong org)
    if ! in_ct "gh repo view '$owner/$REPO_NAME' >/dev/null 2>&1"; then
      if out=$(in_ct "gh repo create '$owner/$REPO_NAME' --private" 2>&1); then
        ok "đã tạo repo private: $owner/$REPO_NAME"
      else
        warn "không tạo được repo. Nguyên văn lỗi:"; printf '     %s\n' "$out" | head -5
      fi
    fi
    in_ct "cd '$BRAIN' && git remote set-url origin '$want'"
    ok "đã đổi remote → $want"
    url="$want"
  else
    ok "remote đúng: $url"
  fi
  # KHÔNG nuốt lỗi push
  if out=$(in_ct "cd '$BRAIN' && git push -u origin HEAD" 2>&1); then
    ok "đã push"
  else
    warn "push thất bại. Nguyên văn lỗi:"
    printf '     %s\n' "$out" | head -6
    echo "     403 = PAT thiếu quyền ghi trên org $REPO_OWNER"
    echo "     (fine-grained PAT: Resource owner phải là org, Contents=Read+write,"
    echo "      và org phải approve token trong Settings → Personal access tokens)"
  fi
else
  me=$(in_ct "gh api user --jq .login 2>/dev/null" || true)
  me="$(printf '%s' "$me" | tr -d '\r\n ')"
  [[ -n "$me" ]] && ok "tài khoản GitHub: $me" \
                 || warn "không đọc được username (gh api user lỗi) — token hỏng/hết hạn?"
  # ưu tiên org đã cấu hình; không có thì rơi về tài khoản cá nhân
  owner="${REPO_OWNER:-$me}"
  target="${owner:+$owner/}$REPO_NAME"
  ok "sẽ tạo: $target"
  # KHÔNG nuốt lỗi: in nguyên văn thông báo của gh để biết đường sửa
  if out=$(in_ct "cd '$BRAIN' && gh repo create '$target' --private --source . --push" 2>&1); then
    ok "đã tạo repo private + push: $target"
  else
    warn "gh repo create thất bại. Nguyên văn lỗi:"
    printf '     %s\n' "$out" | head -6
    echo "     Thường gặp: PAT fine-grained thiếu quyền 'Administration: Read and write'"
    echo "     (quyền tạo repo) — hoặc tạo repo bằng tay trên github.com rồi chạy:"
    echo "     docker exec $CONTAINER bash -c \"cd $BRAIN && git remote add origin <URL> && git push -u origin HEAD\""
  fi
fi

# --- 5. quét secret -------------------------------------------------------------
bold "[5/5] Quét secret trong vault"
if in_ct "cd '$BRAIN' && grep -rInE 'gh[pous]_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{20,}|github_pat_' --exclude=.gitignore . >/dev/null 2>&1"; then
  fail "PHÁT HIỆN chuỗi giống secret trong brain! Kiểm tra ngay:"
  in_ct "cd '$BRAIN' && grep -rInE 'gh[pous]_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{20,}|github_pat_' --exclude=.gitignore . | cut -c1-120"
  exit 1
fi
ok "sạch"

echo
bold "Xong. Kiểm tra nhanh từ Telegram:"
echo "  \"đọc brain rồi tóm tắt: dự án nào đang chạy, có bài học vận hành gì?\""
