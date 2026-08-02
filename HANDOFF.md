# HANDOFF.md — context for Claude Cowork / Claude Code
# (You are picking up a project designed in a claude.ai chat on 2026-07-22)

## What this project is
A self-hosted "super assistant": phone chat apps → OpenClaw gateway on a VPS
→ three AI desks. The user (Hung, HCMC, prefers simple non-abstract
explanations, VN/EN) talks by text or voice notes.

## Architecture decided
- Host: Rocky Linux VPS, everything in ONE Docker container (SELinux :Z mounts).
- Desk 1 "zalo-desk": Zalo channel → native OpenClaw agent → DeepSeek API.
  (Gemini subscription was ruled out: Google killed CLI subscription login
  June 2026; user refused paid/extra keys.)
- Desk 2 "claude-desk": Telegram → Claude Code via OpenClaw ACP (acpx plugin),
  paid by Claude subscription. permissionMode approve-all (headless).
- Desk 3 "codex-desk": optional 2nd Telegram bot → Codex via ACP,
  paid by ChatGPT subscription.
- Shared long-term memory: workspace/NOTES.md, read+appended by all desks.
  Per-worker rules: workspace/projects/CLAUDE.md (has deploy guardrails:
  staging only, CONFIRM word for destructive ops) and AGENTS.md.

## Files in this folder
Dockerfile, docker-compose.yml, .env.example,
scripts/setup-acp.sh (configures OpenClaw via CLI + worker logins), workspace/*,
README.md (full ordered setup checklist — start there).
NOTE 2026-07-23: config/openclaw.json was removed on purpose — config is now
applied via `openclaw config set` / `openclaw models set` in setup-acp.sh
(per docs.openclaw.ai/providers/openrouter and /tools/acp-agents/), so it
can't drift from the installed OpenClaw version. Telegram→Claude binding is
done from chat: /acp spawn claude --bind here

## Known open items
1. ✅ DONE 2026-07-22 (Cowork): merged template hardening from
   ~/git/zaloclaw/zaloclaw-infra-api/app/template/docker-compose.yml
   (cap_drop, no-new-privileges, pids_limit, init, mem_limit,
   NODE_OPTIONS ipv4first, log rotation, /healthz healthcheck).
   Skipped on purpose: Traefik labels, external networks, published ports.
2. Validate openclaw.json keys against installed OpenClaw version
   (`openclaw doctor`) — schema moves fast.
3. Replace example deploy command in CLAUDE.md with the real script.
4. Zalo plugin is experimental — test text before voice.
5. ✅ DONE 2026-07-22 (Cowork): checked ../zalo-claudecode — it is an
   unrelated work project (LLM eval for Claude Code at Zalo). No overlap.

## Personal Goal Dashboard (added 2026-08-01, Cowork)
Notion page "Personal Goal Dashboard" (id 3af5960f92fb80a7aaeac6af150cd589)
holds the user's PERSONAL tasks + big goals per work line — separate from
the assistant task board (setup-notion.sh). Pieces:
- scripts/setup-goals.sh    → DBs "Personal Tasks" + "Goals", seeds 4 lines
  (za-cs, za-standard, zclaw, zBiz); ids in .env + ~/.openclaw/notion-*-db-id
- scripts/setup-reminder.sh → OpenClaw cron "morning-review", 09:00
  Asia/Ho_Chi_Minh, isolated, announces to owner Telegram; Monday adds
  weekly view + per-line progress
- workspace/bin/personal-task → helper (create/done/list/report)
- brain/projects/{za-standard,zclaw,zbiz}.md updated/created — NOT yet
  committed to the brain repo; next desk session should commit+push them.
Item 2 (link personal tasks ↔ assistant tasks) postponed by user.

## First Cowork task suggestion
"Read HANDOFF.md and README.md, compare with ../zalo-claudecode, merge the
compose files, then walk me through README step 1."
