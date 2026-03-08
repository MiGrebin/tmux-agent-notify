#!/usr/bin/env bash

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export TMUX_AGENT_NOTIFY_ROOT="$CURRENT_DIR"
"$CURRENT_DIR/scripts/exec.sh" bootstrap
