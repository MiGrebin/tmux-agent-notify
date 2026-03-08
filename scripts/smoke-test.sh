#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SESSION_NAME="${1:-agent-notify-smoke}"
INTERVAL_SECONDS="${AGENT_NOTIFY_SMOKE_INTERVAL:-1}"

cleanup() {
tmux kill-session -t "$SESSION_NAME" >/dev/null 2>&1 || true
}

cleanup

root_pane="$(tmux new-session -d -P -F '#{pane_id}' -s "$SESSION_NAME" -n agents -c "$ROOT_DIR" "$ROOT_DIR/test/bin/codex attention")"
tmux set-option -t "$SESSION_NAME" -g @agent_notify_interval "$INTERVAL_SECONDS"
tmux set-option -t "$SESSION_NAME" -g @agent_notify_dashboard_mode "popup"
tmux set-option -t "$SESSION_NAME" -g @agent_notify_popup_width "80%"
tmux set-option -t "$SESSION_NAME" -g @agent_notify_popup_height "70%"
tmux select-pane -t "$root_pane" -T "codex"
done_pane="$(tmux split-window -h -P -F '#{pane_id}' -t "$root_pane" -c "$ROOT_DIR" "$ROOT_DIR/test/bin/claude done")"
tmux select-pane -t "$done_pane" -T "claude"
busy_pane="$(tmux split-window -v -P -F '#{pane_id}' -t "$done_pane" -c "$ROOT_DIR" "$ROOT_DIR/test/bin/codex busy")"
tmux select-pane -t "$busy_pane" -T "codex"
tmux select-layout -t "$SESSION_NAME:agents" tiled >/dev/null
tmux run-shell "$ROOT_DIR/agent-notify.tmux"

sleep "$((INTERVAL_SECONDS + 2))"

status="$(tmux show-option -gqv @agent_notify_status)"
attention_panes="$(tmux show-option -gqv @agent_notify_attention_panes)"
done_panes="$(tmux show-option -gqv @agent_notify_done_panes)"
all_panes="$(tmux show-option -gqv @agent_notify_all_panes)"
session_summary="$(tmux show-option -t "$SESSION_NAME" -qv @agent_notify_session_summary)"

printf 'Session: %s\n' "$SESSION_NAME"
printf 'Status: %s\n' "${status:-<empty>}"
printf 'Session summary: %s\n' "${session_summary:-<empty>}"
printf 'Attention panes: %s\n' "${attention_panes:-<empty>}"
printf 'Done panes: %s\n' "${done_panes:-<empty>}"
printf 'All panes: %s\n' "${all_panes:-<empty>}"
printf '\nPane metadata:\n'
tmux list-panes -t "$SESSION_NAME:agents" -F '#{pane_id} kind=#{@agent_notify_pane_kind_label} state=#{@agent_notify_pane_state} label=#{@agent_notify_pane_label}'

if [[ "$session_summary" != *"!1"* ]] || [[ "$session_summary" != *"D1"* ]] || [[ "$session_summary" != *"B1"* ]]; then
  printf '\nSmoke test failed: expected session summary with !1, D1, and B1 counts.\n' >&2
  exit 1
fi

printf '\nAttach with:\n'
printf 'tmux attach -t %s\n' "$SESSION_NAME"
