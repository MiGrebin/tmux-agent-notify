#!/usr/bin/env bash

set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CURRENT_DIR/helpers.sh"

open_legacy_popup() {
  local width height title
  width="$(get_tmux_option "@agent_notify_popup_width" "80%")"
  height="$(get_tmux_option "@agent_notify_popup_height" "70%")"
  title="$(get_tmux_option "@agent_notify_popup_title" "Agent Sessions")"

  tmux display-popup -E -w "$width" -h "$height" -T "$title" "$CURRENT_DIR/popup.sh"
}

open_native_dashboard() {
  local all_panes filter format template target_pane

  all_panes="$(get_tmux_option "@agent_notify_all_panes" "")"
  if [ -z "$all_panes" ]; then
    tmux display-message "No Codex or Claude panes found"
    exit 0
  fi

  target_pane="$(tmux display-message -p '#{pane_id}' 2>/dev/null || true)"
  if [ -z "$target_pane" ]; then
    tmux display-message "No active tmux pane found"
    exit 1
  fi

  filter='#{?pane_format,#{==:#{@agent_notify_is_agent},1},#{?window_format,#{==:#{@agent_notify_window_has_agents},1},#{==:#{@agent_notify_session_has_agents},1}}}'
  format='#{?pane_format,#{@agent_notify_pane_state_badge} #[fg=colour81]#{@agent_notify_pane_kind_label}#[default] #[fg=colour250]#{window_index}.#{pane_index}#[default] #{@agent_notify_pane_label},#{?window_format,#[fg=colour250]#{window_index}#[default] #{window_name}#{?#{!=:#{@agent_notify_window_summary},},  #{@agent_notify_window_summary},},#[bold]#{session_name}#[default]#{?#{==:#{session_name},#{client_session}}, #[fg=colour39 bold][current]#[default],}#{?#{!=:#{@agent_notify_session_summary},},  #{@agent_notify_session_summary},}}}'
  template="switch-client -t '%%' \\; select-window -t '%%' \\; select-pane -t '%%'"

  tmux choose-tree -t "$target_pane" -N -Z -O name -f "$filter" -F "$format" "$template"
}

main() {
  local dashboard_mode
  dashboard_mode="$(get_tmux_option "@agent_notify_dashboard_mode" "popup")"

  case "$dashboard_mode" in
    popup)
      open_legacy_popup
      ;;
    *)
      open_native_dashboard
      ;;
  esac
}

main
