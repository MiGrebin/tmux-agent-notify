#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_PATH="$ROOT_DIR/bin/agent-notify"

export TMUX_AGENT_NOTIFY_ROOT="$ROOT_DIR"
export GOCACHE="${GOCACHE:-$ROOT_DIR/.gocache}"

needs_build="0"

if [ ! -x "$BIN_PATH" ]; then
  needs_build="1"
elif [ "$ROOT_DIR/go.mod" -nt "$BIN_PATH" ]; then
  needs_build="1"
elif [ -n "$(find "$ROOT_DIR/cmd" "$ROOT_DIR/internal" -name '*.go' -newer "$BIN_PATH" -print -quit 2>/dev/null)" ]; then
  needs_build="1"
fi

if [ "$needs_build" = "1" ]; then
  mkdir -p "$ROOT_DIR/bin" "$GOCACHE"
  (
    cd "$ROOT_DIR"
    go build -o "$BIN_PATH" ./cmd/agent-notify
  )
fi

exec "$BIN_PATH" "$@"
