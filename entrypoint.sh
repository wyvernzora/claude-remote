#!/bin/bash
set -euo pipefail

CREDS_SRC="/var/run/secrets/claude/credentials.json"
CREDS_DST="/home/claude/.claude/.credentials.json"
BOOTSTRAP_MODE=0

# claude needs to be able to refresh its access token in place, so the
# credentials file must live somewhere writable. The state volume mount
# is writable; the Secret mount (if present) is read-only — copy once
# from Secret into ~/.claude on a fresh state, then leave any in-pod
# refreshes alone.
#
# If no credentials are present at all, fall into bootstrap mode: keep
# the pod alive with an idle tmux session so the operator can
# 'kubectl exec -- claude auth login' to populate the state volume.
# After login, restart the pod — entrypoint finds the credentials and
# starts claude remote-control normally.
if [[ ! -f "$CREDS_DST" ]]; then
  if [[ -f "$CREDS_SRC" ]]; then
    install -m 600 "$CREDS_SRC" "$CREDS_DST"
    echo "Seeded $CREDS_DST from $CREDS_SRC"
  else
    BOOTSTRAP_MODE=1
  fi
fi

if [[ $BOOTSTRAP_MODE -eq 1 ]]; then
  echo "============================================"
  echo "BOOTSTRAP MODE — no credentials found at $CREDS_DST."
  echo ""
  echo "  kubectl exec -it deployment/claude-remote -- bash"
  echo "  # inside:"
  echo "  #   claude auth login"
  echo "  #   exit"
  echo ""
  echo "Then restart the pod (e.g. 'kubectl delete pod -l app=claude-remote')."
  echo "Next boot will find the credentials and start remote-control."
  echo "============================================"
  # Keep an idle tmux session so claude-health passes during bootstrap.
  mkdir -p /tmp/claude
  tmux new-session -d -s claude "sleep infinity"
  exec tail -f /dev/null
fi

MCP_CONFIG_SRC=/var/run/config/claude/.mcp.json
if [[ ! -f "$MCP_CONFIG_SRC" ]]; then
  echo "WARNING: MCP config not found at $MCP_CONFIG_SRC" >&2
  echo "Agent will start with no MCP servers." >&2
fi

# Patch ~/.claude.json so remote-control doesn't block on prompts that no
# human is around to answer, and merge in user-scope MCP servers from the
# mounted ConfigMap (if present):
#  - hasTrustDialogAccepted (per-project):     "Workspace not trusted."
#  - remoteDialogSeen (global):                first-time "Enable Remote Control?" dialog
#  - remoteControlSpawnMode (global):          spawn-mode "Enable Remote Control? (y/n)" prompt
#  - mcpServers (global / user-scope):         merged from $MCP_CONFIG_SRC if mounted
# The file exists post-login; in bootstrap mode it's untouched.
CLAUDE_CONFIG=/home/claude/.claude.json
if [[ -f "$CLAUDE_CONFIG" ]]; then
  jq_args=()
  jq_filter='
        . + {remoteDialogSeen: true, remoteControlSpawnMode: "same-dir"} |
        .projects["/workspace"] |= ((. // {}) + {hasTrustDialogAccepted: true})
      '
  if [[ -f "$MCP_CONFIG_SRC" ]]; then
    jq_args+=("--slurpfile" "mcp" "$MCP_CONFIG_SRC")
    jq_filter+='
        | .mcpServers = ((.mcpServers // {}) + ($mcp[0].mcpServers // {}))
      '
  fi
  tmp=$(mktemp)
  if jq "${jq_args[@]}" "$jq_filter" "$CLAUDE_CONFIG" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$CLAUDE_CONFIG"
    chmod 600 "$CLAUDE_CONFIG"
    echo "Patched ~/.claude.json: dialogs pre-acknowledged, /workspace trusted, MCP servers merged"
  else
    rm -f "$tmp"
    echo "WARNING: failed to patch $CLAUDE_CONFIG; remote-control may block on prompts" >&2
  fi
fi

mkdir -p /tmp/claude
SESSION_LOG=/tmp/claude/session.log
: > "$SESSION_LOG"

PERMISSION_MODE="${CLAUDE_PERMISSION_MODE:-auto}"
tmux new-session -d -s claude \
  "claude remote-control --permission-mode $PERMISSION_MODE 2>&1 | tee $SESSION_LOG"

echo "Waiting for remote-control session URL..."
for i in {1..60}; do
  if grep -q "https://" "$SESSION_LOG" 2>/dev/null; then
    echo "============================================"
    echo "REMOTE CONTROL URL:"
    grep "https://" "$SESSION_LOG"
    echo "============================================"
    break
  fi
  sleep 1
done

if ! grep -q "https://" "$SESSION_LOG"; then
  echo "ERROR: remote-control session URL did not appear within 60 seconds" >&2
  cat "$SESSION_LOG" >&2
  exit 1
fi

exec tail -F "$SESSION_LOG"
