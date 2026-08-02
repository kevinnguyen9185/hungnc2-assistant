# hungnc2-assistant super-assistant container
# Host OS (Rocky Linux) does not matter — inside the container we use Debian.
FROM node:22-bookworm

# --- system basics the harnesses need (git, gh for PRs, ssh, audio for voice notes) ---
RUN apt-get update && apt-get install -y --no-install-recommends \
    git openssh-client curl ca-certificates jq ripgrep ffmpeg \
    # bubblewrap = the `bwrap` sandbox Codex uses on Linux. Without it every
    # sandboxed command dies with: "bubblewrap is unavailable ... panicked"
    # (code 101) and Codex falls back to slow escalation retries.
    bubblewrap \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
         -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
         > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*

# --- corporate root CA (VNG proxy) into the SYSTEM trust store ---
# NODE_EXTRA_CA_CERTS only covers Node tools (openclaw, claude).
# Codex (Rust), git, curl, gh read the system store instead.
# Put your .crt files in ./certs/ before building; empty folder = no-op.
COPY certs/ /usr/local/share/ca-certificates/
RUN update-ca-certificates

# --- non-root user (all auth tokens will live in this user's HOME) ---
RUN useradd -m -s /bin/bash openclaw
USER openclaw
WORKDIR /home/openclaw
ENV NPM_CONFIG_PREFIX=/home/openclaw/.npm-global
ENV PATH=/home/openclaw/.npm-global/bin:$PATH

# --- the receptionist + the two workers ---
# Pin versions once you are happy (e.g. openclaw@x.y.z) for reproducible builds.
# --include=optional: @openai/codex's real binary lives in an optional
# per-platform package; without it `codex` fails with "spawn ... ENOENT".
RUN npm install -g --include=optional openclaw @anthropic-ai/claude-code @openai/codex \
    && openclaw --version && claude --version \
    # Fallback: npm sometimes still skips codex's platform binary (arm64).
    && (codex --version || ( \
         arch="$(node -p 'process.arch === "arm64" ? "arm64" : "x64"')" \
         && npm install -g "@openai/codex-linux-${arch}" \
         && codex --version ))

# Workspace where the agents live and share memory
RUN mkdir -p /home/openclaw/workspace

# Gateway stays on loopback inside the container; nothing is published
# to the internet. Chat platforms are reached via OUTBOUND connections only.
#
# First-boot fix: a fresh container has NO config yet, and the gateway
# refuses to start unconfigured ("Missing config. Run `openclaw setup` or
# set gateway.mode=local"). We seed the one required key — gateway.mode=local
# ("this gateway runs everything on this machine") — then start. Idempotent:
# on later boots the key is already there. All real config is applied
# afterwards by scripts/setup-acp.sh via the CLI.
# (plain `bash -c`, NOT `bash -lc`: a login shell re-reads /etc/profile,
#  which resets PATH and loses the npm-global dir where openclaw lives)
# --bind lan + OPENCLAW_GATEWAY_TOKEN (from .env): same pattern as the
# zaloclaw-infra-api work template. The gateway listens inside the container
# with token auth; docker-compose decides what (if anything) is reachable
# from outside — on the Mac we publish it on 127.0.0.1 only.
CMD ["bash", "-c", "openclaw config set gateway.mode local && exec openclaw gateway --bind lan --verbose"]
