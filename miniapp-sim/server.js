// =============================================================================
// miniapp-sim — end-to-end SIMULATION of the miniapp ACP auth flows.
//
// Zero dependencies. Run:   node miniapp-sim/server.js   → http://localhost:8790
//
// What it simulates:
//   * the miniapp backend API  (same surface as miniapp-backend/server.js:
//     /api/providers, /start, /status, /callback, /input)
//   * the provider OAuth servers (fake OpenAI / Anthropic / GitHub pages)
//   * the worker CLIs           (state machines instead of real ptys)
//
// The point: demonstrate the ZERO COPY-PASTE UX before wiring real providers.
// The webview shell (public/shell.html) intercepts navigation to
// localhost:PORT — exactly what the native Zalo/Telegram webview layer will
// do — and completes each flow automatically.
//
// NOT for production. No auth, secrets are fake, everything is in-memory.
// =============================================================================
"use strict";

const http = require("http");
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

const PORT = Number(process.env.PORT || 8790);
const rand = (n) => crypto.randomBytes(n).toString("hex");

// provider -> session state machine
// states: idle | starting | awaiting_approval | processing | success | error
const sessions = {};
const PROVIDER_NAMES = ["claude", "codex", "copilot"];
const connected = { claude: false, codex: false, copilot: false };

// --- fake "CLI" flows ---------------------------------------------------------
function startLogin(provider) {
  const s = {
    state: "starting",
    authUrl: null,
    error: null,
    log: [`spawned fake ${provider} login CLI`],
    // flow secrets
    oauthState: rand(8),
    code: null,
    userCode: null,
    deviceApproved: false,
  };
  sessions[provider] = s;

  // simulate CLI startup time, then "print" the auth URL
  setTimeout(() => {
    if (provider === "codex") {
      s.code = "AC_" + rand(12); // authorization code the fake IdP will issue
      s.authUrl =
        `/fake/openai/authorize?state=${s.oauthState}` +
        `&redirect_uri=${encodeURIComponent("http://localhost:1455/auth/callback")}`;
      s.log.push("fake codex CLI: callback server listening on 127.0.0.1:1455");
    } else if (provider === "claude") {
      s.code = "CLAUDE-" + rand(4).toUpperCase();
      s.authUrl = `/fake/anthropic/authorize?state=${s.oauthState}`;
      s.log.push("fake claude CLI: waiting for paste-back code on stdin");
    } else if (provider === "copilot") {
      s.userCode = (rand(2) + "-" + rand(2)).toUpperCase();
      s.authUrl = `/fake/github/device?user_code=${s.userCode}`;
      s.log.push(`fake copilot CLI: device code ${s.userCode}, polling GitHub...`);
    }
    s.state = "awaiting_approval";
  }, 700);
}

function finish(provider, ok, why) {
  const s = sessions[provider];
  s.state = ok ? "success" : "error";
  if (!ok) s.error = why;
  if (ok) {
    connected[provider] = true;
    s.log.push("probe OK — tokens written to shared volume (simulated)");
    if (provider === "codex") {
      s.log.push("sync: auth.json → acpx/codex-home + trust projects (simulated)");
    }
  }
}

// --- tiny http plumbing ---------------------------------------------------------
function json(res, status, obj) {
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(JSON.stringify(obj));
}
function html(res, body) {
  res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
  res.end(body);
}
function readBody(req) {
  return new Promise((resolve) => {
    let b = "";
    req.on("data", (d) => (b += d));
    req.on("end", () => {
      try { resolve(JSON.parse(b || "{}")); } catch (_) { resolve({}); }
    });
  });
}

// --- fake provider pages ----------------------------------------------------------
// Real webviews intercept NAVIGATION. Same-origin iframes can't fake that
// perfectly, so approve buttons call parent.postMessage({type:"navigate",url})
// — the shell treats that exactly like a native navigation event.
const pageStyle = `<style>
  body{font-family:system-ui;background:#f6f7f9;color:#111;display:flex;justify-content:center;padding-top:40px}
  .box{background:#fff;border:1px solid #ddd;border-radius:12px;padding:24px;width:300px;text-align:center}
  button{border:0;border-radius:8px;padding:10px 18px;font-size:1em;color:#fff;cursor:pointer}
  .code{font-size:1.4em;letter-spacing:2px;font-weight:700;background:#eef;border-radius:8px;padding:10px;margin:12px 0}
  input{padding:10px;font-size:1.1em;text-align:center;letter-spacing:2px;width:80%;margin:10px 0}
</style>`;

function fakeOpenAIPage(q) {
  const s = sessions.codex || {};
  const redirect = q.get("redirect_uri") || "http://localhost:1455/auth/callback";
  const target = `${redirect}?code=${s.code}&state=${q.get("state")}`;
  return `${pageStyle}<div class="box">
    <h3>⬡ OpenAI (fake)</h3><p>Codex CLI wants to access your account.</p>
    <button style="background:#10a37f" onclick='parent.postMessage({type:"navigate",url:${JSON.stringify(target)}},"*")'>
      Sign in &amp; Approve</button>
    <p style="font-size:.8em;color:#888">On approve, this page navigates to<br>localhost:1455 — the webview intercepts it.</p>
  </div>`;
}

function fakeAnthropicPage(q) {
  const s = sessions.claude || {};
  return `${pageStyle}<div class="box">
    <h3>✳ Anthropic (fake)</h3><p>Claude Code wants to sign in.</p>
    <button style="background:#d97757" onclick="approve()">Sign in &amp; Approve</button>
    <div id="after" style="display:none">
      <p>Copy this code into your terminal:</p>
      <div class="code">${s.code}</div>
      <p style="font-size:.8em;color:#888">…except you won't: the webview reads it<br>off this page automatically.</p>
    </div>
    <script>
      function approve(){
        document.getElementById("after").style.display="block";
        parent.postMessage({type:"page-code",code:${JSON.stringify(s.code)}},"*");
      }
    </script>
  </div>`;
}

function fakeGitHubPage(q) {
  return `${pageStyle}<div class="box">
    <h3>⌂ GitHub (fake)</h3><p>Device activation</p>
    <input id="uc" value="${q.get("user_code") || ""}">
    <p style="font-size:.8em;color:#888">Pre-filled by the webview — just tap.</p>
    <button style="background:#238636" onclick="authz()">Authorize</button>
    <p id="done" style="display:none">✔ Device authorized. You can close this.</p>
    <script>
      function authz(){
        fetch("/fake/github/approve",{method:"POST",headers:{"Content-Type":"application/json"},
          body:JSON.stringify({user_code:document.getElementById("uc").value})})
          .then(()=>{document.getElementById("done").style.display="block"});
      }
    </script>
  </div>`;
}

// --- server -------------------------------------------------------------------------
const server = http.createServer(async (req, res) => {
  const u = new URL(req.url, `http://localhost:${PORT}`);
  const p = u.pathname;

  // shell UI
  if (p === "/" || p === "/shell.html") {
    return html(res, fs.readFileSync(path.join(__dirname, "public", "shell.html"), "utf8"));
  }

  // fake provider pages
  if (p === "/fake/openai/authorize") return html(res, fakeOpenAIPage(u.searchParams));
  if (p === "/fake/anthropic/authorize") return html(res, fakeAnthropicPage(u.searchParams));
  if (p === "/fake/github/device") return html(res, fakeGitHubPage(u.searchParams));
  if (p === "/fake/github/approve" && req.method === "POST") {
    const body = await readBody(req);
    const s = sessions.copilot;
    if (s && body.user_code === s.userCode) {
      s.deviceApproved = true;
      s.log.push("fake GitHub: device approved by user");
      return json(res, 200, { ok: true });
    }
    return json(res, 400, { error: "wrong code" });
  }

  // API (same surface as the real backend)
  const m = p.match(/^\/api\/auth\/(\w+)\/(start|status|callback|input|cancel)$/);
  if (p === "/api/providers") {
    const out = {};
    for (const n of PROVIDER_NAMES) {
      out[n] = { loggedIn: connected[n], loginState: sessions[n] ? sessions[n].state : "idle" };
    }
    return json(res, 200, out);
  }
  if (m) {
    const [, provider, action] = m;
    if (!PROVIDER_NAMES.includes(provider)) return json(res, 404, { error: "unknown provider" });
    const s = sessions[provider];

    if (action === "start" && req.method === "POST") {
      startLogin(provider);
      return json(res, 200, { ok: true, state: "starting" });
    }
    if (action === "status") {
      if (!s) return json(res, 200, { state: "idle" });
      // copilot's fake CLI "poll loop": approval flips it to success
      if (provider === "copilot" && s.state === "awaiting_approval" && s.deviceApproved) {
        s.state = "processing";
        s.log.push("fake copilot CLI: poll returned access token");
        setTimeout(() => finish("copilot", true), 900);
      }
      return json(res, 200, {
        state: s.state, authUrl: s.authUrl, userCode: s.userCode,
        error: s.error, log: s.log,
      });
    }
    if (action === "callback" && req.method === "POST") {
      const { url } = await readBody(req);
      if (!s) return json(res, 409, { error: "no login in progress" });
      let cu;
      try { cu = new URL(url); } catch (_) { return json(res, 400, { error: "invalid url" }); }
      if (cu.hostname !== "localhost" && cu.hostname !== "127.0.0.1") {
        return json(res, 400, { error: "expected a localhost callback URL" });
      }
      if (cu.searchParams.get("code") !== s.code || cu.searchParams.get("state") !== s.oauthState) {
        s.log.push("callback replay REJECTED (bad code/state)");
        return json(res, 400, { error: "bad code/state" });
      }
      s.state = "processing";
      s.log.push(`callback replayed onto 127.0.0.1:${cu.port} (simulated) — exchanging code for tokens`);
      setTimeout(() => finish(provider, true), 1200);
      return json(res, 200, { ok: true });
    }
    if (action === "input" && req.method === "POST") {
      const { text } = await readBody(req);
      if (!s) return json(res, 409, { error: "no login in progress" });
      if ((text || "").trim() !== s.code) {
        s.log.push("stdin code REJECTED");
        return json(res, 400, { error: "wrong code" });
      }
      s.state = "processing";
      s.log.push("code written to fake CLI stdin — exchanging for tokens");
      setTimeout(() => finish(provider, true), 1000);
      return json(res, 200, { ok: true });
    }
    if (action === "cancel" && req.method === "POST") {
      if (s) s.state = "idle";
      return json(res, 200, { ok: true });
    }
  }

  res.writeHead(404); res.end("not found");
});

server.listen(PORT, () => {
  console.log(`miniapp-sim: open http://localhost:${PORT}`);
});
