#!/bin/bash
# claude-health — exit 0 if Claude tmux session is alive, non-zero otherwise.
set -euo pipefail
TMUX_SESSION="${TMUX_SESSION:-claude}"
exec tmux has-session -t "$TMUX_SESSION"
