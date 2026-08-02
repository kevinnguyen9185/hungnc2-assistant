// =============================================================================
// miniapp-backend — browser-driven auth setup for ACP workers.
//
// The problem it solves:
//   Provider logins (claude, codex) are interactive CLI flows whose OAuth
//   callback goes to localhost:PORT — unreachable when OpenClaw runs on a
//   remote server and the user is on a phone.
//
// How it solves it (zero copy-paste):
//   1. This service runs IN THE SAME environment as the workers (same volumes:
//      ~/.claude, ~/.codex, ~/.openclaw), so it runs the login CLIs itself.
//   2. POST /api/auth/:provider/start spawns the login in a pty and captures
//      the auth URL from its output. The miniapp opens that URL.
//   3. The provider redirects the browser to http://localhost:PORT/callback...
//      The miniapp WEBVIEW intercepts that navigation and POSTs the full URL
//      to /api/auth/:provider/callback — which replays it against the CLI's
//      callback server on THIS machine's loopback. Login completes.
//   4. For flows that print a paste-code instead, POST /api/auth/:provider/input
//      forwards whatever the user typed to the CLI's stdin.
//
// Security: every /api route requires X-Api-Token == MINIAPP_API_TOKEN (.env).
// In production put this behind HTTPS (Traefik) and your miniapp's user auth.
// This service mints credentials — treat it like a password manager.
// =============================================================================
"use strict";

const express = require("express");
const pty = require("node-pty");
const { execFile } = require("child_process");
const http = require("http");
const fs = require("fs");
const os = require("os");
const path = require("path");

const PORT = Number(process.env.PORT || 8788);
const TOKEN = process.env.MINIAPP_API_TOKEN || "";
const PROJECTS_DIR = "/home/openclaw/workspace/projects";

// --- provider registry: add copilot etc. here later --------------------------
const PROVIDERS = {
  claude: {
    login: { cmd: "claude", args: ["/login"] },
    probe: { cmd: "claude", args: ["-p", "ping", "--max-turns", "1"] },
    // First-run wizard screens: the highlighted default is fine on each —
    // the backend "presses Enter" like a human would. Each rule fires once.
    // don't surface the auth URL until these params are present (a partial
    // URL gives "Invalid OAuth Request / Missing state parameter")
    urlParams: ["state=", "code_challenge="],
    // after login, claude does NOT exit — it drops into the chat REPL.
    // When this matches, credentials are already on disk: close the pty
    // so onExit → probe → success can run.
    successRe: /Login\s*successful|Logged\s*in\s*as/i,
    // NOTE: \s* between every word — the TUI positions text with cursor
    // escapes, so after ANSI-stripping the words often have NO spaces
    // between them ("trustthisfolder").
    autoAdvance: [
      { name: "theme picker",  re: /Choose\s*the\s*text\s*style/i },
      { name: "continue note", re: /Press\s*Enter\s*to\s*continue/i },
      { name: "trust folder",  re: /trust\s*this\s*folder/i },
      // corporate cert/proxy env (OUR OWN setup: certs/ + NODE_EXTRA_CA_CERTS)
      // makes Claude Code ask for consent — the default "Yes, I trust" is
      // correct here because these settings came from this very compose file
      { name: "managed settings", re: /Managed\s*settings\s*require\s*approval|trust\s*these\s*settings/i },
      { name: "managed settings", re: /trust\s*these\s*settings|Managed\s*settings\s*require\s*approval/i },
      { name: "login method",  re: /Select\s*login\s*method|account\s*with\s*subscription/i },
    ],
  },
  codex: {
    login: { cmd: "codex", args: ["login"] },
    probe: { cmd: "codex", args: ["login", "status"] },
    urlParams: ["redirect_uri=", "state="],
    afterSuccess: syncCodexHome,
  },
};

// provider -> { state, output, authUrl, redirectPort, error, pty, startedAt }
// states: idle | starting | awaiting_approval | processing | success | error
const sessions = {};

// --- helpers ------------------------------------------------------------------
function stripAnsi(s) {
  return s
    .replace(/\x1b\[[^a-zA-Z\x1b]*[a-zA-Z]/g, "")   // CSI incl. ESC[>0q variants
    .replace(/\x1b\][^\x07\x1b]*(\x07|\x1b\\)/g, "") // OSC
    .replace(/\x1bP[^\x1b]*\x1b\\/g, "")             // DCS
    .replace(/\x1b[=>]/g, "");                        // keypad modes
}

// A truncated OAuth URL is worse than none (→ "Missing state parameter").
// Only accept the URL once its required params are all present.
function findAuthUrl(text, requiredParams) {
  const urls = text.match(/https:\/\/[^\s"'<>\]│┃║)]+/g);
  if (!urls) return null;
  return (
    urls.find(
      (u) =>
        /auth|oauth|login|device|authorize/i.test(u) &&
        (requiredParams || []).every((p) => u.includes(p))
    ) || null
  );
}

// If the auth URL carries redirect_uri=http://localhost:PORT/..., remember the
// port so /callback knows where to replay. Falls back to the URL in the body.
function redirectPortFrom(url) {
  try {
    const r = new URL(url).searchParams.get("redirect_uri");
    if (!r) return null;
    const ru = new URL(r);
    if (ru.hostname === "localhost" || ru.hostname === "127.0.0.1") {
      return Number(ru.port || 80);
    }
  } catch (_) {}
  return null;
}

function probe(provider, cb) {
  const p = PROVIDERS[provider].probe;
  execFile(p.cmd, p.args, { timeout: 60000 }, (err) => cb(!err));
}

// The fix that made codex work under acpx (see scripts/setup-acp.sh):
// the adapter runs codex with an ISOLATED home that needs auth.json + trust.
function syncCodexHome() {
  try {
    const home = os.homedir();
    const ch = path.join(home, ".openclaw", "acpx", "codex-home");
    fs.mkdirSync(ch, { recursive: true });
    const src = path.join(home, ".codex", "auth.json");
    if (fs.existsSync(src)) {
      fs.copyFileSync(src, path.join(ch, "auth.json"));
      fs.chmodSync(path.join(ch, "auth.json"), 0o600);
    }
    const cfg = path.join(ch, "config.toml");
    const trustHeader = `[projects."${PROJECTS_DIR}"]`;
    const existing = fs.existsSync(cfg) ? fs.readFileSync(cfg, "utf8") : "";
    if (!existing.includes(trustHeader)) {
      fs.appendFileSync(cfg, `\n${trustHeader}\ntrust_level = "trusted"\n`);
    }
    console.log("[sync] codex-home auth + trust synced");
  } catch (e) {
    console.error("[sync] codex-home sync failed:", e.message);
  }
}

// --- login lifecycle ------------------------------------------------------------
// Fresh ~/.claude → Claude Code shows an interactive first-run wizard
// (theme picker) BEFORE any login URL, and a headless pty sits stuck there.
// Pre-seeding its config marks onboarding done so /login prints the URL.
function seedClaudeConfig() {
  const f = path.join(os.homedir(), ".claude.json");
  if (!fs.existsSync(f)) {
    fs.writeFileSync(f, JSON.stringify({ theme: "dark", hasCompletedOnboarding: true }) + "\n");
    console.log("[claude] seeded ~/.claude.json (skip first-run wizard)");
  }
}

function startLogin(provider) {
  const def = PROVIDERS[provider];
  const old = sessions[provider];
  if (old && old.pty) {
    try { old.pty.kill(); } catch (_) {}
  }
  if (provider === "claude") seedClaudeConfig();
  const s = {
    state: "starting",
    output: "",
    authUrl: null,
    redirectPort: null,
    error: null,
    pty: null,
    startedAt: Date.now(),
  };
  sessions[provider] = s;

  const term = pty.spawn(def.login.cmd, def.login.args, {
    name: "xterm-256color",
    cols: 512, // OAuth URLs are LONG; keep them on one visual line so the
    rows: 40,  // TUI can't split them with cursor-positioning escapes
    env: { ...process.env, BROWSER: "echo", NO_COLOR: "1" },
  });
  s.pty = term;

  s.answered = {};
  term.onData((d) => {
    s.output += d;
    if (s.output.length > 40000) s.output = s.output.slice(-20000);
    const plain = stripAnsi(s.output);
    if (!s.authUrl) {
      // auto-advance known interactive wizard screens (once each)
      for (const rule of def.autoAdvance || []) {
        if (!s.answered[rule.name] && rule.re.test(plain)) {
          s.answered[rule.name] = true;
          s.log = s.log || [];
          console.log(`[${provider}] auto-advancing wizard screen: ${rule.name}`);
          setTimeout(() => { try { term.write("\r"); } catch (_) {} }, 400);
        }
      }
      // Match with line breaks INTACT: cols=512 keeps the URL on one line,
      // and the newline after it is the terminator. Joining lines glued the
      // next line's text onto the URL ("...state=xxxPastecodehere") →
      // corrupted state param → "Invalid code" at the paste-back step.
      const url = findAuthUrl(plain, def.urlParams);
      if (url) {
        s.authUrl = url;
        s.redirectPort = redirectPortFrom(url);
        s.state = "awaiting_approval";
      }
    }
    if (def.successRe && !s.successSeen && def.successRe.test(plain)) {
      s.successSeen = true;
      console.log(`[${provider}] login success detected — closing CLI`);
      setTimeout(() => { try { term.kill(); } catch (_) {} }, 1500);
    }
  });

  term.onExit(({ exitCode }) => {
    s.pty = null;
    probe(provider, (ok) => {
      s.state = ok ? "success" : "error";
      if (!ok) {
        s.error = `login process exited (code ${exitCode}) but provider is still not logged in`;
      } else if (def.afterSuccess) {
        def.afterSuccess();
      }
    });
  });
}

// --- HTTP API ---------------------------------------------------------------------
const app = express();
app.use(express.json());
app.use(express.static(path.join(__dirname, "public")));

app.use("/api", (req, res, next) => {
  if (!TOKEN) return res.status(500).json({ error: "MINIAPP_API_TOKEN not configured" });
  if (req.get("X-Api-Token") !== TOKEN) return res.status(401).json({ error: "bad token" });
  next();
});

// which providers exist + are they currently logged in
app.get("/api/providers", (req, res) => {
  const names = Object.keys(PROVIDERS);
  let pending = names.length;
  const out = {};
  names.forEach((n) => {
    probe(n, (ok) => {
      out[n] = {
        loggedIn: ok,
        loginState: sessions[n] ? sessions[n].state : "idle",
      };
      if (--pending === 0) res.json(out);
    });
  });
});

app.post("/api/auth/:provider/start", (req, res) => {
  const { provider } = req.params;
  if (!PROVIDERS[provider]) return res.status(404).json({ error: "unknown provider" });
  startLogin(provider);
  res.json({ ok: true, state: "starting" });
});

app.get("/api/auth/:provider/status", (req, res) => {
  const s = sessions[req.params.provider];
  if (!s) return res.json({ state: "idle" });
  res.json({
    state: s.state,
    authUrl: s.authUrl,
    redirectPort: s.redirectPort,
    error: s.error,
    // raw tail for debugging fragile CLI parsing — the escape hatch
    outputTail: stripAnsi(s.output).slice(-1500),
  });
});

// The zero-copy-paste endpoint. The miniapp webview intercepts the browser's
// navigation to http://localhost:PORT/callback?... and posts that URL here;
// we replay it against the CLI's callback server on OUR loopback.
app.post("/api/auth/:provider/callback", (req, res) => {
  const s = sessions[req.params.provider];
  const { url } = req.body || {};
  if (!s || !s.pty) return res.status(409).json({ error: "no login in progress" });
  let u;
  try { u = new URL(url); } catch (_) {
    return res.status(400).json({ error: "invalid url" });
  }
  if (u.hostname !== "localhost" && u.hostname !== "127.0.0.1") {
    return res.status(400).json({ error: "expected a localhost callback URL" });
  }
  const port = Number(u.port) || s.redirectPort || 1455;
  s.state = "processing";
  http
    .get({ host: "127.0.0.1", port, path: u.pathname + u.search }, (r) => {
      r.resume();
      res.json({ ok: true, upstreamStatus: r.statusCode });
    })
    .on("error", (e) => {
      s.state = "awaiting_approval";
      res.status(502).json({ error: "callback replay failed: " + e.message });
    });
});

// Fallback for paste-code flows (e.g. claude prints a code to paste back):
// forwards user input to the CLI's stdin.
app.post("/api/auth/:provider/input", (req, res) => {
  const s = sessions[req.params.provider];
  const { text } = req.body || {};
  if (!s || !s.pty) return res.status(409).json({ error: "no login in progress" });
  if (typeof text !== "string" || !text.length) {
    return res.status(400).json({ error: "text required" });
  }
  s.state = "processing";
  // paste, settle, THEN press Enter — sending "code\r" in one write can
  // reach the TUI's input widget before it finishes consuming the paste,
  // leaving the code typed but never submitted
  s.pty.write(text.trim());
  setTimeout(() => { try { s.pty.write("\r"); } catch (_) {} }, 500);
  res.json({ ok: true });
});

app.post("/api/auth/:provider/cancel", (req, res) => {
  const s = sessions[req.params.provider];
  if (s && s.pty) { try { s.pty.kill(); } catch (_) {} }
  if (s) s.state = "idle";
  res.json({ ok: true });
});

app.listen(PORT, "0.0.0.0", () => {
  console.log(`miniapp-backend listening on :${PORT}`);
  if (!TOKEN) console.warn("WARNING: MINIAPP_API_TOKEN is empty — API is unusable until set");
});
