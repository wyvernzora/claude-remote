# syntax=docker/dockerfile:1.23

# ---- builder ----
FROM node:24-slim AS builder

WORKDIR /build

COPY package.json package-lock.json ./

RUN npm ci --omit=dev

RUN cp -L node_modules/.bin/claude /tmp/claude && \
    chmod +x /tmp/claude && \
    /tmp/claude --version

# ---- runtime ----
FROM debian:bookworm-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      tmux \
      ca-certificates \
      git \
      ripgrep \
      jq && \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder /tmp/claude /usr/local/bin/claude

ENV DISABLE_AUTOUPDATER=1

RUN useradd -m -u 1001 -s /bin/bash claude && \
    mkdir -p /workspace /home/claude/.claude && \
    chown -R claude:claude /workspace /home/claude

COPY --chown=claude:claude --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chown=claude:claude --chmod=755 mcp-ctl.sh /usr/local/bin/mcp-ctl
COPY --chown=claude:claude --chmod=755 claude-health.sh /usr/local/bin/claude-health

USER claude
WORKDIR /workspace

# Mount /home/claude (whole home dir) not /home/claude/.claude — claude auth
# login writes BOTH ~/.claude/.credentials.json AND ~/.claude.json (root-level
# dotfile holding oauthAccount.organizationUuid). A subdir-only mount loses
# the latter on pod restart and remote-control fails with "Unable to determine
# your organization for Remote Control eligibility."
VOLUME ["/home/claude", "/workspace"]

RUN claude --version

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
