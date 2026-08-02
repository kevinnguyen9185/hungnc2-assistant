# hungnc2-assistant — super assistant blueprint (v1)

Phone (Zalo / Telegram) → OpenClaw gateway on your VPS → three desks:

| Desk | Channel | Brain | Pays with |
|---|---|---|---|
| `zalo-desk` | Zalo | DeepSeek v4 Flash via OpenRouter (native OpenClaw agent, full OpenClaw memory) | OpenRouter API key |
| `claude-desk` | Telegram (default) | Claude Code via ACP | your Claude subscription |
| `codex-desk` | Telegram (2nd bot, optional) | Codex via ACP | your ChatGPT subscription |

Shared long-term memory: `workspace/NOTES.md` — every desk reads it, every desk appends to it.

---

## Setup checklist (Rocky Linux VPS)

### 1. Docker on Rocky
```bash
sudo dnf -y install dnf-plugins-core
sudo dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
sudo dnf -y install docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo systemctl enable --now docker
sudo usermod -aG docker $USER   # then log out and back in
```
SELinux stays ENFORCING — the compose file already uses `:Z` on all mounts.

### 2. Get the files onto the VPS
```bash
scp -r hungnc2-assistant/ user@your-vps:~/ && ssh user@your-vps && cd hungnc2-assistant
```

### 3. Secrets
```bash
cp .env.example .env && chmod 600 .env && nano .env
```
Fill in `TELEGRAM_BOT_TOKEN` (from @BotFather) and `OPENROUTER_API_KEY`
(from openrouter.ai/keys — DeepSeek runs behind OpenRouter).

### 4. First start
```bash
mkdir -p data/openclaw data/claude data/codex
docker compose up -d --build
docker compose logs -f     # watch it come up; Ctrl-C to stop watching
```
There is NO hand-written openclaw.json — all config is applied in step 5
through the OpenClaw CLI, so it always matches your installed version.

### 5. Configure + wire the workers (one script)
```bash
./scripts/setup-acp.sh              # claude + codex
```
It configures the Telegram channel from .env, sets the default model
(`openclaw models set openrouter/deepseek/deepseek-v4-flash` — see
docs.openclaw.ai/providers/openrouter), walks you through the one-time
headless subscription logins, installs + enables the acpx plugin with
`permissionMode approve-all` (see docs.openclaw.ai/tools/acp-agents/),
restarts the gateway, and runs doctor.
Tokens land in `./data/claude` and `./data/codex`, so they survive rebuilds.

### 6. Connect the channels
- **Telegram**: message your bot → it replies with a pairing code → approve:
  `docker compose exec openclaw openclaw pairing approve <code>`
  then bind the chat to Claude Code: send `/acp spawn claude --bind here`
- **Zalo**: official-bot route uses `ZALO_BOT_TOKEN`; the personal route
  shows a QR in the logs during onboarding — scan it with your Zalo app.
  (Zalo support is experimental — test text before voice.)

### 7. Put a real repo in the workshop
```bash
cd workspace/projects
git clone git@github.com:you/yourapp.git
gh auth login        # run INSIDE the container: docker compose exec -it openclaw gh auth login
```
Then edit `workspace/projects/CLAUDE.md` → replace the example deploy
command with your real one.

### 8. Smoke tests, in order
1. Zalo: "xin chào" → DeepSeek desk answers.
2. Telegram: "hello" → Claude Code desk answers.
3. Telegram: `/acp doctor` → all green.
4. Telegram: "what's in NOTES.md?" → proves shared memory works.
5. Telegram: send a **voice note** → transcription path works.
6. Telegram: "deploy our latest PR to staging" → the real thing.

### 9. Personal Goal Dashboard + nhắc nhở 9h sáng (tuỳ chọn)
Task cá nhân + mục tiêu các line việc (za-cs, za-standard, zclaw, zBiz)
trên Notion, tách khỏi task board của assistant.
1. Trên notion.so: page "Personal Goal Dashboard" → ⋯ → Connections →
   chọn integration (giống bước setup-notion).
2. `./scripts/setup-goals.sh` — tạo database "Personal Tasks" + "Goals",
   seed 4 line việc.
3. `./scripts/setup-reminder.sh` — cron `morning-review`: 9h sáng
   (Asia/Ho_Chi_Minh) nhắn Telegram task hôm nay + quá hạn; thứ Hai kèm
   tổng quan tuần + tiến độ các line.
Muốn sửa nội dung nhắc: sửa PROMPT trong `setup-reminder.sh` rồi chạy lại.
Helper cho desk: `~/workspace/bin/personal-task` (create/done/list/report).

---

## Day-2 operations
- **Update everything**: `docker compose build --pull && docker compose up -d`
- **Expired login** (happens occasionally): `./scripts/setup-acp.sh claude`
- **Backups**: `tar czf backup.tgz data/ workspace/ .env` — that's the whole assistant.
- **Add a worker desk later** (e.g. another harness): add a case block in
  `setup-acp.sh`, an npm package in the Dockerfile, an agent entry +
  binding in openclaw.json. Three small edits.

## Security posture (do not skip)
- VPS: SSH keys only, `PasswordAuthentication no`, firewall closed inbound
  except SSH. The assistant needs **zero** open inbound ports.
- Keep `dmPolicy: pairing` — never set open policies.
- `approve-all` permission mode means Claude/Codex run real commands.
  The guardrails live in CLAUDE.md / AGENTS.md — keep them, extend them.
- No production credentials on this box. Staging only.
