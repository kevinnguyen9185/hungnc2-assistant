# miniapp-backend — runs the worker login CLIs next to their auth volumes.
# Build context is the REPO ROOT (see docker-compose.yml) so certs/ is visible.
FROM node:22-bookworm

# node-pty needs a compiler; git for good measure
RUN apt-get update && apt-get install -y --no-install-recommends \
    git ca-certificates python3 make g++ \
    && rm -rf /var/lib/apt/lists/*

# corporate root CA into the system store (Rust codex, git, curl)
COPY certs/ /usr/local/share/ca-certificates/
RUN update-ca-certificates

# SAME user/home layout as the openclaw container, so the shared volumes
# (~/.claude, ~/.codex, ~/.openclaw) mean the same thing in both.
RUN useradd -m -s /bin/bash openclaw
USER openclaw
ENV NPM_CONFIG_PREFIX=/home/openclaw/.npm-global
ENV PATH=/home/openclaw/.npm-global/bin:$PATH

# the worker CLIs this service logs in.
# --include=optional is REQUIRED: @openai/codex ships its real binary in an
# optional per-platform package (@openai/codex-linux-x64). If npm skips it,
# `codex` dies instantly with "spawn ...codex ENOENT" → login exits code 1.
# The verify step fails the build loudly instead of shipping a broken image.
RUN npm install -g --include=optional @anthropic-ai/claude-code @openai/codex \
    && claude --version \
    # Fallback: npm sometimes still skips the platform binary (seen on arm64).
    # Install it explicitly for this image's architecture, then verify.
    && (codex --version || ( \
         arch="$(node -p 'process.arch === "arm64" ? "arm64" : "x64"')" \
         && npm install -g "@openai/codex-linux-${arch}" \
         && codex --version ))

WORKDIR /home/openclaw/app
COPY --chown=openclaw:openclaw miniapp-backend/package.json ./
RUN npm install
COPY --chown=openclaw:openclaw miniapp-backend/server.js ./
COPY --chown=openclaw:openclaw miniapp-backend/public ./public

ENV PORT=8788
CMD ["node", "server.js"]
