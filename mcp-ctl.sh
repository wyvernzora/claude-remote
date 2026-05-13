#!/bin/bash
# mcp-ctl — control MCP server connections in the running Claude Code session.
# Talks to the Claude TUI through tmux send-keys.

set -euo pipefail

TMUX_SESSION="${TMUX_SESSION:-claude}"

usage() {
  cat <<EOF
Usage: mcp-ctl <command> [args]

Commands:
  list                 Show MCP server status (out-of-band, via 'claude mcp list')
  reconnect [server]   Send /mcp reconnect to the running session (interactive menu if no server given)
  reload               Send /mcp to bring up the interactive menu
  keys <keystrokes>    Send arbitrary keystrokes to the Claude TUI (requires MCP_CTL_ALLOW_RAW_KEYS=1)

Environment:
  TMUX_SESSION              tmux session name (default: claude)
  MCP_CTL_ALLOW_RAW_KEYS    set to 1 to enable the 'keys' subcommand

Examples:
  kubectl exec deployment/claude-remote -- mcp-ctl list
  kubectl exec deployment/claude-remote -- mcp-ctl reconnect kura
  kubectl exec deployment/claude-remote -- mcp-ctl reload
EOF
}

require_tmux_session() {
  if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    echo "error: tmux session '$TMUX_SESSION' not found" >&2
    echo "is the Claude Code container actually running?" >&2
    exit 2
  fi
}

cmd_list() {
  exec claude mcp list
}

cmd_reconnect() {
  require_tmux_session
  local server="${1:-}"

  if [[ -n "$server" ]]; then
    tmux send-keys -t "$TMUX_SESSION" "/mcp reconnect $server" Enter
    echo "sent: /mcp reconnect $server"
  else
    tmux send-keys -t "$TMUX_SESSION" "/mcp" Enter
    echo "sent: /mcp (interactive menu — drive from remote-control)"
  fi
}

cmd_reload() {
  require_tmux_session
  tmux send-keys -t "$TMUX_SESSION" "/mcp" Enter
  echo "sent: /mcp"
}

cmd_keys() {
  if [[ "${MCP_CTL_ALLOW_RAW_KEYS:-}" != "1" ]]; then
    echo "error: raw key injection disabled" >&2
    echo "to enable: kubectl exec ... -e MCP_CTL_ALLOW_RAW_KEYS=1 ..." >&2
    exit 3
  fi
  require_tmux_session
  if [[ $# -eq 0 ]]; then
    echo "error: keys command requires at least one argument" >&2
    exit 2
  fi
  tmux send-keys -t "$TMUX_SESSION" "$@"
  echo "sent: $*"
}

case "${1:-}" in
  list)           shift; cmd_list ;;
  reconnect)      shift; cmd_reconnect "$@" ;;
  reload)         shift; cmd_reload ;;
  keys)           shift; cmd_keys "$@" ;;
  -h|--help|"")   usage ;;
  *)
    echo "unknown command: $1" >&2
    usage >&2
    exit 2
    ;;
esac
