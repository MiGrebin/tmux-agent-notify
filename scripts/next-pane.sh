#!/usr/bin/env bash

set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CURRENT_DIR/helpers.sh"

pick_next_pane() {
  local panes="$1"
  local last_target="$2"
  local pane
  local found_last="0"

  if [ -z "$panes" ]; then
    return 1
  fi

  for pane in $panes; do
    if [ "$found_last" = "1" ]; then
      printf '%s\n' "$pane"
      return 0
    fi
    if [ "$pane" = "$last_target" ]; then
      found_last="1"
    fi
  done

  for pane in $panes; do
    printf '%s\n' "$pane"
    return 0
  done

  return 1
}

main() {
  local attention_panes done_panes panes last_target next_pane
  attention_panes="$(get_tmux_option "@agent_notify_attention_panes" "")"
  done_panes="$(get_tmux_option "@agent_notify_done_panes" "")"

  if [ -n "$attention_panes" ]; then
    panes="$attention_panes"
  else
    panes="$done_panes"
  fi

  if [ -z "$panes" ]; then
    tmux display-message "No Codex or Claude panes are waiting"
    exit 0
  fi

  last_target="$(get_tmux_option "@agent_notify_last_target" "")"
  next_pane="$(pick_next_pane "$panes" "$last_target")"

  if ! switch_to_pane "$next_pane"; then
    tmux display-message "Pane ${next_pane} is no longer available"
    exit 1
  fi

  set_tmux_option "@agent_notify_last_target" "$next_pane"
}

main
