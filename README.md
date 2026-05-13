# claude-remote-container

In-cluster Claude Code with remote-control. First pass ships the container image and CI.

> ## ⚠️ Subscription compliance — read first
>
> This container authenticates with a **personal claude.ai Pro/Max subscription**. That subscription is licensed for **interactive use by a single human operator**, not for programmatic or automated workloads.
>
> **Acceptable uses of this image:**
> - Driving the container from Claude Code's official remote-control clients (claude.ai/code in a browser, the Claude mobile app).
> - Sessions initiated and steered by you, the human subscriber, in real time.
>
> **NOT acceptable:**
> - Invoking the container or its session via API automation, cron jobs, CI pipelines, batch scripts, webhooks, third-party agents, or any other unattended/programmatic trigger.
> - Sharing the remote-control session URL with other people. The subscription is per-seat.
> - Running multiple concurrent instances against the same subscription.
> - Anything that resembles "Claude-as-a-service" against your personal entitlement.
>
> Programmatic / automated workloads require Anthropic API credits and a different auth path (`ANTHROPIC_API_KEY`), which this image is **not** configured for and which remote-control explicitly rejects.
>
> If you need automation, build a separate image authed against the API and pay per-token. Do not point automation at this one.

## What the image does

- Boots `claude remote-control` inside a tmux session at container start.
- Prints the remote-control session URL to stdout (visible in `docker logs` / `kubectl logs`).
- Open the URL in claude.ai/code or the Claude mobile app to drive the session.
- Ships three helper commands on `$PATH`:
  - `mcp-ctl` — control MCP server connections in the running session
  - `claude-health` — exit 0 if the tmux session is alive (for liveness probes)
  - `claude` — the binary itself

## Build

Local single-arch:

```
docker build -t claude-remote:dev .
docker run --rm claude-remote:dev claude --version
```

Multi-arch (matches CI):

```
docker buildx create --use
docker buildx build --platform linux/amd64 -t claude-remote:dev-amd64 --load .
docker buildx build --platform linux/arm64 -t claude-remote:dev-arm64 --load .
```

CI builds and pushes to GHCR on merge to `main`. PRs build amd64-only and run smoke tests; main builds multi-arch (`linux/amd64,linux/arm64`) and pushes `:VERSION` + `:latest`.

## Run

Remote-control requires a **full-scope OAuth login** (`claude auth login`). Long-lived tokens from `claude setup-token` / `CLAUDE_CODE_OAUTH_TOKEN` are inference-only and **will not work**. Env-only auth (`CLAUDE_CODE_OAUTH_REFRESH_TOKEN` + `CLAUDE_CODE_OAUTH_SCOPES`) is rejected too — it works for inference but doesn't produce a "logged in" state, which remote-control demands. Account/organization metadata that `claude auth login` writes lives in `~/.claude` alongside `.credentials.json`, so the cleanest bootstrap is to log in *inside* the container against a writable state volume.

### First boot — bootstrap mode

```
docker volume create claude-state

docker run --rm -it \
  --name claude-remote \
  -v claude-state:/home/claude \
  claude-remote:dev
```

With no credentials on the volume, entrypoint prints the bootstrap recipe and idles. From a second terminal:

```
docker exec -it claude-remote bash
# inside:
#   claude auth login        # paste-back code flow
#   claude auth status       # confirm
#   exit
```

Stop the bootstrap container (Ctrl-C in the first terminal). Credentials are now in the `claude-state` volume.

### Real run

```
docker run --rm \
  --name claude-remote \
  -v claude-state:/home/claude \
  -v "$PWD/workspace:/workspace" \
  claude-remote:dev
```

Watch stdout for `REMOTE CONTROL URL:`. Open the URL in claude.ai/code or the mobile app.

**Rotation.** Anthropic may rotate refresh tokens on each refresh; the writable state volume captures rotations in place and persists across container restarts. If the refresh token gets invalidated for any reason, re-login: stop the container, delete the volume (or just `~/.claude/.credentials.json` inside it), repeat the bootstrap.

### Optional — pre-seed credentials from a file

If you already have a `.credentials.json` on hand, you can skip the in-container login by mounting it as a read-only source — entrypoint copies it onto the state volume on first boot. The state volume still has to be writable.

```
docker run --rm \
  -v "$PWD/.credentials.json:/var/run/secrets/claude/credentials.json:ro" \
  -v claude-state:/home/claude \
  claude-remote:dev
```

This only seeds `.credentials.json`; account/org metadata still has to be fetched on first remote-control connect.

## Volumes

The image declares two volumes:

- `/workspace` — project files. Mount a host dir or named volume for persistence.
- `/home/claude` — entire home dir for the `claude` user. Holds `.claude/` (conversation history, settings, MCP cache, `.credentials.json`) **and** the root-level `.claude.json` (auth/account/org metadata). Both files are required for remote-control; mounting only `~/.claude` loses `.claude.json` and breaks the org-eligibility check on restart.

Both are chowned to uid 1001 (the `claude` user) at image build time.

## MCP configuration

Mount a `.mcp.json` at `/var/run/config/claude/.mcp.json` (read-only is fine). Entrypoint merges its `mcpServers` map into `~/.claude.json` user-scope on every boot, so servers apply across any cwd, no per-project approval needed. Example file:

```json
{
  "mcpServers": {
    "kura": {
      "type": "sse",
      "url": "http://kura.example.svc.cluster.local:8080/mcp"
    }
  }
}
```

If the file is missing the container starts with no MCP servers and logs a warning.

## Helper: `mcp-ctl`

Runs from inside the container (e.g. `docker exec` or `kubectl exec`).

```
mcp-ctl list                 # show MCP server status (out-of-band)
mcp-ctl reload               # open /mcp menu in the running session
mcp-ctl reconnect <server>   # send /mcp reconnect <server>
mcp-ctl --help
```

## Knobs

Env vars the entrypoint reads:

- `CLAUDE_PERMISSION_MODE` — passed as `--permission-mode` to `claude remote-control`. Default `auto`. Values: `acceptEdits`, `auto`, `bypassPermissions`, `default`, `dontAsk`, `plan`.
- `TMUX_SESSION` — tmux session name claude runs in. Default `claude`. Used by `mcp-ctl` and `claude-health`.

## Helper: `claude-health`

Exits 0 if the tmux session named `claude` exists, non-zero otherwise. Ready to wire as a k8s `exec` liveness probe when manifests land.

## Updates

Renovate watches `@anthropic-ai/claude-code` in `package.json` and opens a grouped PR on Monday mornings (`claude-code-bump` label). Review changelog, merge, CI builds and publishes new image.

## Known limitations

- Session URL rotates on container restart (no `--session-id` upstream yet).
- `/mcp` command not reachable through remote-control — that's why `mcp-ctl` exists.
- Stdio MCP servers do not auto-reconnect — prefer HTTP/SSE.
- Subscription compliance: single human operator only.
- No NetworkPolicy hardening, no liveness/readiness probes wired in the reference manifests, no automated OAuth credential rotation.
