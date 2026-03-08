#!/usr/bin/env bash

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CURRENT_DIR/scripts/helpers.sh"

default_key_binding="A"
default_popup_key="a"
default_dashboard_mode="native"
default_interval="5"
default_capture_lines="80"
default_popup_width="80%"
default_popup_height="70%"
default_popup_title="Agent Sessions"
default_process_pattern='(/bin/codex|/@openai/codex|(^|[[:space:]/])claude([[:space:]]|$)|/@anthropic-ai/claude-code)'
default_attention_patterns='Would you like to run the following command\?|Press enter to confirm|Yes, proceed|don.t ask again|needs input|waiting for input|select an option|choose an option|continue\?|approve|approval|permission required|requires approval|allow.*command'
default_done_prompt_patterns='^[[:space:]]*[›>][[:space:]]'

set_default_option() {
  local option="$1"
  local value="$2"

  if [ -z "$(get_tmux_option "$option" "")" ]; then
    set_tmux_option "$option" "$value"
  fi
}

ensure_status_segment() {
  local status_right
  status_right="$(get_tmux_option "status-right" "")"

  case "$status_right" in
    *"#{@agent_notify_status}"*) return ;;
  esac

  if [ -n "$status_right" ]; then
    set_tmux_option "status-right" "${status_right} #{@agent_notify_status}"
  else
    set_tmux_option "status-right" "#{@agent_notify_status}"
  fi
}

set_key_binding() {
  local key_binding
  key_binding="$(get_tmux_option "@agent_notify_key" "$default_key_binding")"
  tmux bind-key "$key_binding" run-shell "$CURRENT_DIR/scripts/next-pane.sh"
}

set_popup_binding() {
  local popup_key
  popup_key="$(get_tmux_option "@agent_notify_popup_key" "$default_popup_key")"
  tmux bind-key "$popup_key" run-shell "$CURRENT_DIR/scripts/open-popup.sh"
}

main() {
  set_default_option "@agent_notify_key" "$default_key_binding"
  set_default_option "@agent_notify_popup_key" "$default_popup_key"
  set_default_option "@agent_notify_dashboard_mode" "$default_dashboard_mode"
  set_default_option "@agent_notify_interval" "$default_interval"
  set_default_option "@agent_notify_capture_lines" "$default_capture_lines"
  set_default_option "@agent_notify_popup_width" "$default_popup_width"
  set_default_option "@agent_notify_popup_height" "$default_popup_height"
  set_default_option "@agent_notify_popup_title" "$default_popup_title"
  set_default_option "@agent_notify_process_pattern" "$default_process_pattern"
  set_default_option "@agent_notify_attention_patterns" "$default_attention_patterns"
  set_default_option "@agent_notify_done_prompt_patterns" "$default_done_prompt_patterns"
  set_default_option "@agent_notify_status" ""
  set_default_option "@agent_notify_attention_panes" ""
  set_default_option "@agent_notify_done_panes" ""
  set_default_option "@agent_notify_all_panes" ""

  ensure_status_segment
  set_key_binding
  set_popup_binding

  tmux run-shell -b "$CURRENT_DIR/scripts/monitor.sh start"
}

main
