#!/usr/bin/env bash
# =============================================================================
# sync-projects.sh — đồng bộ HAI CHIỀU giữa workspace/projects và org GitHub
#
# CHIỀU XUỐNG (mặc định) — GitHub là nguồn chân lý (brain/conventions.md):
#   1. repo có trên GitHub mà máy CHƯA có   → clone về
#   2. repo máy đã có                        → fetch + pull --rebase
#   3. repo `brain`                          → đồng bộ ở workspace/brain
#   4. thư mục local không thuộc org         → vẫn pull theo remote của nó
#
# CHIỀU LÊN (phải bật bằng --up) — đẩy việc làm dưới máy lên GitHub:
#   5. thay đổi chưa commit  → commit (danh tính "Assistant (sync)")
#   6. commit chưa push      → push (commit TRƯỚC pull --rebase, rồi mới push)
#   7. branch chưa có upstream → push -u
#   8. repo local chưa có trên GitHub → --create-remote để tạo repo private
#
# An toàn (idempotent — chạy lại bao nhiêu lần cũng được):
#   - QUÉT SECRET trước mỗi commit: thấy password/token/private key trong nội
#     dung sắp commit thì CHẶN cả repo đó, không có cờ nào ép được. Sửa rồi chạy lại.
#   - Bỏ qua rác: .DS_Store, _to_delete/, *.lock, __pycache__, node_modules…
#   - worktree bẩn      → không pull (trừ khi có --stash / --up)
#   - detached HEAD     → BỎ QUA
#   - KHÔNG bao giờ ghi token vào remote URL hay .git/config
#
# Cách dùng (từ thư mục chứa docker-compose.yml):
#   ./scripts/sync-projects.sh                  # chỉ chiều xuống: clone thiếu + pull
#   ./scripts/sync-projects.sh --dry-run        # chỉ xem sẽ làm gì
#   ./scripts/sync-projects.sh --up             # HAI CHIỀU: pull + commit + push
#   ./scripts/sync-projects.sh --up --dry-run   # xem sẽ commit gì trước khi làm thật
#   ./scripts/sync-projects.sh --up -m "..."    # tự đặt nội dung commit
#   ./scripts/sync-projects.sh --up --create-remote  # tạo repo cho project local mới
#   ./scripts/sync-projects.sh --push           # chỉ push commit đã có, không commit mới
#   ./scripts/sync-projects.sh --stash          # pull cả khi worktree bẩn (autostash)
#   ./scripts/sync-projects.sh --only za-cs     # chỉ 1 repo (lặp lại cờ được)
#   ./scripts/sync-projects.sh --no-clone       # không clone repo mới, chỉ pull
#   ./scripts/sync-projects.sh --include-archived
#   ORG=my-agents-090185 ./scripts/sync-projects.sh
#
# Token: đọc GH_TOKEN từ .env ở gốc repo (hoặc biến môi trường GH_TOKEN,
# hoặc `gh auth token` nếu có gh). Không in ra giá trị.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WS="${WORKSPACE_DIR:-$REPO_ROOT/workspace}"
PROJECTS_DIR="$WS/projects"
BRAIN_DIR="${BRAIN_DIR:-$WS/brain}"
ORG="${ORG:-my-agents-090185}"

DRY_RUN=0
DO_PUSH=0
DO_UP=0
DO_STASH=0
DO_CLONE=1
DO_CREATE_REMOTE=0
INCLUDE_ARCHIVED=0
ONLY=""   # danh sách "|slug|slug|" — dùng chuỗi thay mảng cho bash 3.2 của macOS
COMMIT_MSG=""
GIT_NAME="${GIT_NAME:-Assistant (sync)}"
GIT_EMAIL="${GIT_EMAIL:-hungnc2@vng.com.vn}"

usage() { sed -n '2,41p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)          DRY_RUN=1 ;;
    --push)             DO_PUSH=1 ;;
    --up)               DO_UP=1; DO_PUSH=1 ;;
    --create-remote)    DO_CREATE_REMOTE=1 ;;
    --message|-m)       COMMIT_MSG="${2:?-m cần nội dung commit}"; shift ;;
    --stash)            DO_STASH=1 ;;
    --no-clone)         DO_CLONE=0 ;;
    --include-archived) INCLUDE_ARCHIVED=1 ;;
    --only)             ONLY="${ONLY}|${2:?--only cần tên repo}"; shift ;;
    --org)              ORG="${2:?--org cần tên org}"; shift ;;
    -h|--help)          usage ;;
    *) printf 'Tham số lạ: %s (xem --help)\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✔\033[0m %s\n' "$*"; }
info() { printf '  · %s\n' "$*"; }
warn() { printf '  \033[33m⚠\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m✘\033[0m %s\n' "$*"; }
# run <câu lệnh dạng chuỗi> — dry-run thì chỉ in ra, không chạy
run()  { if (( DRY_RUN )); then printf '  \033[36m→ (dry-run)\033[0m %s\n' "$1"; else eval "$1"; fi; }

N_CLONED=0 N_PULLED=0 N_UPTODATE=0 N_PUSHED=0 N_SKIPPED=0 N_FAILED=0
N_COMMITTED=0 N_BLOCKED=0 N_REMOTE_CREATED=0

# --- 0. preflight ------------------------------------------------------------
bold "[0/3] Kiểm tra môi trường"
for c in git curl jq; do
  command -v "$c" >/dev/null || { fail "thiếu lệnh '$c'"; exit 1; }
done
ok "git / curl / jq sẵn sàng"

# Token: env → .env → gh auth token. Không in giá trị ra màn hình.
if [[ -z "${GH_TOKEN:-}" && -f "$REPO_ROOT/.env" ]]; then
  GH_TOKEN="$(sed -n 's/^[[:space:]]*GH_TOKEN[[:space:]]*=[[:space:]]*//p' "$REPO_ROOT/.env" \
              | head -1 | tr -d '"'\''' | tr -d '\r')"
fi
if [[ -z "${GH_TOKEN:-}" ]] && command -v gh >/dev/null; then
  GH_TOKEN="$(gh auth token 2>/dev/null || true)"
fi
[[ -n "${GH_TOKEN:-}" ]] || { fail "không tìm thấy GH_TOKEN (env, .env, hay gh auth)"; exit 1; }
export GH_TOKEN
ok "GH_TOKEN đã nạp (không in ra)"

# git dùng token qua askpass tạm thời → token KHÔNG lọt vào remote URL/config
ASKPASS_DIR="$(mktemp -d)"
trap 'rm -rf "$ASKPASS_DIR"' EXIT
cat > "$ASKPASS_DIR/askpass.sh" <<'ASK'
#!/usr/bin/env bash
case "$1" in
  *[Uu]sername*) printf 'x-access-token\n' ;;
  *)             printf '%s\n' "$GH_TOKEN" ;;
esac
ASK
chmod 700 "$ASKPASS_DIR/askpass.sh"
export GIT_ASKPASS="$ASKPASS_DIR/askpass.sh"
export GIT_TERMINAL_PROMPT=0   # thà lỗi còn hơn treo chờ nhập tay

# Mạng VNG chèn proxy MITM → git báo "self signed certificate in certificate
# chain". curl/node đọc SSL_CERT_FILE/NODE_EXTRA_CA_CERTS, git thì KHÔNG —
# git chỉ nghe http.sslCAInfo / GIT_SSL_CAINFO. Tự dò CA bundle cho git.
if [[ -z "${GIT_SSL_CAINFO:-}" ]] && [[ -z "$(git config --get http.sslCAInfo || true)" ]]; then
  for ca in "${SSL_CERT_FILE:-}" "${REQUESTS_CA_BUNDLE:-}" \
            "$HOME/.config/uv/ca-bundle.pem" \
            "${NODE_EXTRA_CA_CERTS:-}" "$REPO_ROOT/certs/za-ecc-root-ca.crt"; do
    if [[ -n "$ca" && -r "$ca" ]]; then
      export GIT_SSL_CAINFO="$ca"
      ok "CA bundle cho git: $ca"
      break
    fi
  done
  [[ -n "${GIT_SSL_CAINFO:-}" ]] || info "không dò được CA bundle riêng — dùng mặc định của git"
fi

mkdir -p "$PROJECTS_DIR"

wanted() { # wanted <slug> — có nằm trong --only không (không có --only = lấy hết)
  [[ -z "$ONLY" ]] && return 0
  [[ "$ONLY|" == *"|$1|"* ]]
}

# --- 1. lấy danh sách repo của org ------------------------------------------
bold "[1/3] Danh sách repo trong org '$ORG'"
REPOS_JSON="$ASKPASS_DIR/repos.json"
: > "$REPOS_JSON"
page=1
while :; do
  body="$(curl -fsS \
    -H "Authorization: Bearer $GH_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/orgs/$ORG/repos?per_page=100&type=all&page=$page" 2>/dev/null)" || {
      fail "gọi GitHub API thất bại (token hết hạn? org sai?)"; exit 1; }
  count="$(jq 'length' <<<"$body")"
  jq -c '.[]' <<<"$body" >> "$REPOS_JSON"
  (( count < 100 )) && break
  page=$(( page + 1 ))
done

filter='.archived == false'
(( INCLUDE_ARCHIVED )) && filter='true'
ROWS="$ASKPASS_DIR/rows.tsv"
jq -r "select($filter) | [.name, .clone_url] | @tsv" "$REPOS_JSON" | sort > "$ROWS"
ok "$(wc -l < "$REPOS_JSON" | tr -d ' ') repo trên GitHub, $(wc -l < "$ROWS" | tr -d ' ') repo sẽ xử lý"

# --- chiều LÊN: lọc rác, quét secret, commit --------------------------------

# File rác không bao giờ commit dù .gitignore của repo chưa chặn.
# `_to_delete/` là rác dọn dẹp; `*.lock.<pid>` là lock git sót lại.
is_noise() { # is_noise <đường dẫn tương đối>
  local p="${1%/}"   # git status in thư mục chưa track kèm dấu / cuối
  case "$p" in
    _to_delete|__pycache__|node_modules|.venv|venv) return 0 ;;
  esac
  case "$p" in
    .DS_Store|*/.DS_Store)          return 0 ;;
    _to_delete/*|*/_to_delete/*)    return 0 ;;
    *.lock|*.lock.[0-9]*)           return 0 ;;
    __pycache__/*|*/__pycache__/*)  return 0 ;;
    *.pyc|node_modules/*|*/node_modules/*) return 0 ;;
    .venv/*|venv/*|*/.venv/*)       return 0 ;;
    *.log|*.tmp|*.swp)              return 0 ;;
  esac
  return 1
}

# Liệt kê các dòng SẼ ĐƯỢC THÊM, dạng "file:dòng:+nội dung".
# Không đụng vào index — file chưa track thì đọc thẳng, file đã track thì diff
# với HEAD. (Bản trước dùng `git add -N` rồi `diff --cached`: sai, vì -N chỉ
# ghi nhận ý định nên diff ra rỗng và bộ quét không thấy gì.)
added_lines() { # added_lines <dir> <file-danh-sách-path>
  local dir="$1" list="$2" p
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    if git -C "$dir" ls-files --error-unmatch -- "$p" >/dev/null 2>&1; then
      git -C "$dir" diff HEAD --unified=0 --no-color -- "$p" \
        | awk '/^\+\+\+ b\//{f=substr($0,7); next}
               /^@@/{split($0,a,"+"); split(a[2],b,","); n=b[1]+0; next}
               /^\+/{print f":"n":"$0; n++}'
    elif grep -Iq . "$dir/$p" 2>/dev/null; then     # bỏ qua file nhị phân
      awk -v f="$p" '{print f":"NR":+"$0}' "$dir/$p"
    fi
  done < "$list"
}

# Quét nội dung SẼ COMMIT tìm secret. Trả về 0 = sạch, 1 = có nghi vấn.
# In ra file:dòng + LÝ DO, KHÔNG BAO GIỜ in giá trị bắt được.
# .gitignore của repo đã chặn .env..., đây là lưới thứ hai cho file mới lạ.
scan_secrets() { # scan_secrets <dir> <file-danh-sách-path>
  local dir="$1" list="$2" hits=0 line file lineno
  # Chuỗi thay-thế rõ ràng là placeholder thì bỏ qua (ví dụ your_password_here)
  local placeholder='your_|_here|changeme|xxxxx|placeholder|<[^>]*>|\*\*\*|example|dummy|redacted'

  while IFS= read -r line; do
    file="${line%%:*}"; line="${line#*:}"
    lineno="${line%%:*}"; line="${line#*:}"
    [[ "$line" =~ ^\+ ]] || continue                       # chỉ xét dòng THÊM MỚI
    printf '%s' "$line" | grep -qiE "$placeholder" && continue

    local why=""
    case "$line" in
      *ghp_*|*github_pat_*|*ghs_*|*gho_*) why="GitHub token" ;;
      *sk-ant-*)                          why="Anthropic API key" ;;
      *xox[baprs]-*)                      why="Slack token" ;;
      *"BEGIN RSA PRIVATE KEY"*|*"BEGIN OPENSSH PRIVATE KEY"*|*"BEGIN PRIVATE KEY"*) why="private key" ;;
    esac
    if [[ -z "$why" ]] && printf '%s' "$line" | grep -qE 'AKIA[0-9A-Z]{16}'; then why="AWS access key"; fi
    if [[ -z "$why" ]] && printf '%s' "$line" | grep -qE 'sk-[A-Za-z0-9_-]{20,}';  then why="API key kiểu sk-"; fi
    # gán mật khẩu/token có giá trị thật (>= 6 ký tự, không phải placeholder)
    if [[ -z "$why" ]] && printf '%s' "$line" \
        | grep -qiE '(password|passwd|pwd|secret|api[_-]?key|access[_-]?token|auth[_-]?token)[[:space:]]*[:=][[:space:]]*"?[^"[:space:]]{6,}'; then
      why="gán password/secret"
    fi
    [[ -n "$why" ]] || continue

    fail "    ⛔ $file:$lineno — nghi có $why"
    hits=$(( hits + 1 ))
    (( hits >= 5 )) && { info "    (còn nữa — cắt bớt)"; break; }
  done < <(added_lines "$dir" "$list")

  (( hits == 0 ))
}

# Stage + commit thay đổi local. Trả 0 nếu có commit mới, 1 nếu không (sạch/bỏ qua).
commit_local() { # commit_local <dir> <label>
  local dir="$1" label="$2" path status n_add=0 skipped=0

  # gom file cần add. `-uall` để thư mục chưa track được liệt kê từng file
  # (mặc định git gộp thành "dir/" → lọc rác và quét secret sẽ bỏ sót).
  # git status đã tôn trọng .gitignore của repo.
  local addlist="$ASKPASS_DIR/add.txt"; : > "$addlist"
  while IFS= read -r status; do
    [[ -n "$status" ]] || continue
    path="${status:3}"
    path="${path#\"}"; path="${path%\"}"
    [[ "$path" == *' -> '* ]] && path="${path##* -> }"     # file đổi tên
    if is_noise "$path"; then
      skipped=$(( skipped + 1 )); continue
    fi
    printf '%s\n' "$path" >> "$addlist"
    n_add=$(( n_add + 1 ))
    # core.quotepath=false: nếu không, tên file tiếng Việt bị escape thành
    # octal ("b\303\241o c\303\241o.md") → add sai đường dẫn, commit trượt file.
  done < <(git -C "$dir" -c core.quotepath=false status --porcelain -uall)

  (( skipped > 0 )) && info "$label: bỏ qua $skipped mục rác (.DS_Store, _to_delete/, *.lock…)"
  if (( n_add == 0 )); then
    return 1
  fi

  # Quét TRƯỚC khi stage — bẩn thì không có gì phải hoàn tác.
  if ! scan_secrets "$dir" "$addlist"; then
    fail "$label: CHẶN COMMIT — nội dung nghi có secret (xem dòng ⛔ ở trên)"
    info "    Xử lý: thêm file vào .gitignore, hoặc xoá giá trị thật rồi chạy lại."
    N_BLOCKED=$(( N_BLOCKED + 1 ))
    return 1
  fi

  if (( DRY_RUN )); then
    printf '  \033[36m→ (dry-run)\033[0m %s: sẽ commit %d mục\n' "$label" "$n_add"
    sed 's/^/      + /' "$addlist" | head -10
    return 1
  fi

  # xargs -0 thay cho --pathspec-from-file (cờ đó cần git >= 2.25, container
  # có thể chạy bản cũ hơn); -0 để tên file có dấu cách vẫn đúng.
  tr '\n' '\0' < "$addlist" | xargs -0 git -C "$dir" add --

  if git -C "$dir" diff --cached --quiet; then
    git -C "$dir" reset -q
    return 1
  fi

  local msg="${COMMIT_MSG:-sync: cập nhật từ $(hostname -s) $(date '+%F %H:%M')}"
  if git -C "$dir" -c user.name="$GIT_NAME" -c user.email="$GIT_EMAIL" commit -qm "$msg"; then
    ok "$label: commit $n_add mục — \"$msg\""
    N_COMMITTED=$(( N_COMMITTED + 1 ))
    return 0
  fi
  fail "$label: commit thất bại"
  git -C "$dir" reset -q
  N_FAILED=$(( N_FAILED + 1 ))
  return 1
}

# --- helpers đồng bộ ---------------------------------------------------------
sync_existing() { # sync_existing <dir> <label>
  local dir="$1" label="$2"

  if [[ ! -d "$dir/.git" ]]; then
    warn "$label: thư mục có sẵn nhưng không phải git repo — bỏ qua"
    N_SKIPPED=$(( N_SKIPPED + 1 )); return
  fi

  local err
  if ! err="$(git -C "$dir" fetch --prune --tags -q origin 2>&1)"; then
    fail "$label: fetch thất bại — $(printf '%s' "$err" | tail -1)"
    N_FAILED=$(( N_FAILED + 1 )); return
  fi

  local branch
  branch="$(git -C "$dir" symbolic-ref --short -q HEAD || true)"
  if [[ -z "$branch" ]]; then
    warn "$label: detached HEAD — chỉ fetch, không pull"
    N_SKIPPED=$(( N_SKIPPED + 1 )); return
  fi

  # CHIỀU LÊN: commit trước khi pull, để rebase phát lại commit local lên trên
  # commit mới của remote (đúng luật pull --rebase trong brain/conventions.md).
  (( DO_UP )) && commit_local "$dir" "$label" || true

  local upstream
  upstream="$(git -C "$dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
  if [[ -z "$upstream" ]]; then
    # branch local chưa từng push → đẩy lên và đặt upstream luôn
    if (( DO_PUSH )) && git -C "$dir" remote get-url origin >/dev/null 2>&1; then
      if run "git -C '$dir' push -q -u origin '$branch'"; then
        ok "$label: push branch mới '$branch' + đặt upstream"
        N_PUSHED=$(( N_PUSHED + 1 ))
      else
        fail "$label: push branch mới '$branch' thất bại"
        N_FAILED=$(( N_FAILED + 1 ))
      fi
    else
      warn "$label: branch '$branch' chưa có upstream — bỏ qua (dùng --push để đẩy lên)"
      N_SKIPPED=$(( N_SKIPPED + 1 ))
    fi
    return
  fi

  local counts behind ahead
  counts="$(git -C "$dir" rev-list --left-right --count "$upstream...HEAD")"
  behind="${counts%%[[:space:]]*}"; ahead="${counts##*[[:space:]]}"

  local dirty=0
  [[ -n "$(git -C "$dir" status --porcelain)" ]] && dirty=1

  if (( behind > 0 )); then
    # Ở chế độ --up, thứ còn bẩn chỉ là rác/bị chặn → autostash được, không mất gì.
    if (( dirty && ! DO_STASH && ! DO_UP )); then
      warn "$label: sau $upstream $behind commit nhưng worktree BẨN — bỏ qua (dùng --stash hoặc --up)"
      N_SKIPPED=$(( N_SKIPPED + 1 )); return
    fi
    local autostash=""
    (( dirty )) && autostash="--autostash"
    if run "git -C '$dir' pull --rebase $autostash -q"; then
      ok "$label: pull --rebase $behind commit ($branch)"
      N_PULLED=$(( N_PULLED + 1 ))
    else
      fail "$label: pull --rebase thất bại (conflict? xử lý tay)"
      N_FAILED=$(( N_FAILED + 1 )); return
    fi
  else
    info "$label: đã mới nhất ($branch)$( (( dirty )) && printf ' — worktree bẩn' )"
    N_UPTODATE=$(( N_UPTODATE + 1 ))
  fi

  if (( ahead > 0 )); then
    if (( DO_PUSH )); then
      if run "git -C '$dir' push -q origin '$branch'"; then
        ok "$label: push $ahead commit lên $branch"
        N_PUSHED=$(( N_PUSHED + 1 ))
      else
        fail "$label: push thất bại"
        N_FAILED=$(( N_FAILED + 1 ))
      fi
    else
      warn "$label: còn $ahead commit CHƯA push (chạy lại với --push)"
    fi
  fi
}

sync_repo() { # sync_repo <slug> <clone_url> <dir>
  local slug="$1" url="$2" dir="$3"
  local label="$slug"
  [[ "$dir" == "$BRAIN_DIR" ]] && label="$slug (workspace/brain)"

  if [[ -e "$dir" ]]; then
    sync_existing "$dir" "$label"
  elif (( DO_CLONE )); then
    if run "git clone -q '$url' '$dir'"; then
      ok "$label: clone mới → ${dir#"$WS"/}"
      N_CLONED=$(( N_CLONED + 1 ))
    else
      fail "$label: clone thất bại"
      N_FAILED=$(( N_FAILED + 1 ))
    fi
  else
    info "$label: chưa có ở máy (--no-clone nên bỏ qua)"
    N_SKIPPED=$(( N_SKIPPED + 1 ))
  fi
}

# --- 2. đồng bộ repo của org ------------------------------------------------
bold "[2/3] Đồng bộ repo của org"
SEEN=""   # "|slug|slug|" — các repo của org nằm dưới projects/
while IFS=$'\t' read -r name url; do
  [[ -n "$name" ]] || continue
  # brain có chỗ riêng, không nằm trong projects/
  if [[ "$name" == "brain" ]]; then
    dir="$BRAIN_DIR"
  else
    dir="$PROJECTS_DIR/$name"
    SEEN="${SEEN}|${name}"
  fi
  wanted "$name" || continue
  sync_repo "$name" "$url" "$dir"
done < "$ROWS"

# --- 3. repo local không thuộc org ------------------------------------------
bold "[3/3] Repo local không có trong org"
found_extra=0
for dir in "$PROJECTS_DIR"/*/; do
  [[ -d "$dir" ]] || continue
  slug="$(basename "$dir")"
  wanted "$slug" || continue
  [[ "$SEEN|" == *"|$slug|"* ]] && continue   # đã xử lý ở bước 2
  found_extra=1
  if [[ ! -d "$dir/.git" ]]; then
    info "$slug: thư mục thường (không phải git repo) — để nguyên"
    continue
  fi

  if git -C "${dir%/}" remote get-url origin >/dev/null 2>&1; then
    warn "$slug: có ở máy nhưng KHÔNG thấy trong org $ORG — vẫn pull theo remote của nó"
    sync_existing "${dir%/}" "$slug"
  elif (( DO_CREATE_REMOTE )); then
    # repo local thuần, chưa có remote → tạo repo private trên org rồi đẩy lên
    (( DO_UP )) && commit_local "${dir%/}" "$slug" || true
    # \$GH_TOKEN để nguyên trong chuỗi → chỉ expand lúc eval, dry-run in ra
    # không lộ giá trị.
    if run "curl -fsS -X POST \
              -H \"Authorization: Bearer \$GH_TOKEN\" \
              -H 'Accept: application/vnd.github+json' \
              'https://api.github.com/orgs/$ORG/repos' \
              -d '{\"name\":\"$slug\",\"private\":true}' >/dev/null"; then
      run "git -C '${dir%/}' remote add origin 'https://github.com/$ORG/$slug.git'"
      br="$(git -C "${dir%/}" symbolic-ref --short -q HEAD || echo main)"
      if run "git -C '${dir%/}' push -q -u origin '$br'"; then
        ok "$slug: tạo repo private $ORG/$slug + push branch '$br'"
        N_REMOTE_CREATED=$(( N_REMOTE_CREATED + 1 )); N_PUSHED=$(( N_PUSHED + 1 ))
      else
        fail "$slug: tạo repo xong nhưng push thất bại"
        N_FAILED=$(( N_FAILED + 1 ))
      fi
    else
      fail "$slug: tạo repo trên GitHub thất bại (token thiếu quyền tạo repo?)"
      N_FAILED=$(( N_FAILED + 1 ))
    fi
  else
    warn "$slug: repo local CHƯA có trên GitHub (không có remote) — dùng --create-remote để đẩy lên"
    N_SKIPPED=$(( N_SKIPPED + 1 ))
  fi
done
(( found_extra )) || info "không có"

# --- tổng kết ----------------------------------------------------------------
printf '\n'
bold "Tổng kết$( (( DRY_RUN )) && printf ' (DRY RUN — chưa đụng gì)' )"
printf '  ↓ xuống:  clone mới %d   pull %d   đã mới nhất %d\n' \
  "$N_CLONED" "$N_PULLED" "$N_UPTODATE"
printf '  ↑ lên:    commit %d   push %d   repo mới trên GitHub %d\n' \
  "$N_COMMITTED" "$N_PUSHED" "$N_REMOTE_CREATED"
printf '  bỏ qua %d   CHẶN vì secret %d   lỗi %d\n' \
  "$N_SKIPPED" "$N_BLOCKED" "$N_FAILED"
printf '  Thư mục: %s\n' "$PROJECTS_DIR"
(( DO_UP )) || printf '  (chỉ đồng bộ chiều xuống — thêm --up để commit + push chiều lên)\n'
if (( N_BLOCKED > 0 )); then
  printf '\n'
  warn "Có $N_BLOCKED repo bị CHẶN vì nghi lộ secret. Sửa xong chạy lại — KHÔNG dùng cờ nào để ép."
fi

(( N_FAILED == 0 && N_BLOCKED == 0 ))
