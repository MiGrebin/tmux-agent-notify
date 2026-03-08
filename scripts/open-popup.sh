#!/usr/bin/env bash

set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CURRENT_DIR/helpers.sh"

main() {
  local width height title
  width="$(get_tmux_option "@agent_notify_popup_width" "80%")"
  height="$(get_tmux_option "@agent_notify_popup_height" "70%")"
  title="$(get_tmux_option "@agent_notify_popup_title" "Agent Sessions")"

  tmux display-popup -E -w "$width" -h "$height" -T "$title" "$CURRENT_DIR/popup.sh"
}

main
