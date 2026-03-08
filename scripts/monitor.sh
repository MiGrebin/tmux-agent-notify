#!/usr/bin/env bash

set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CURRENT_DIR/helpers.sh"

monitor_pid_option="@agent_notify_monitor_pid"
status_option="@agent_notify_status"
attention_panes_option="@agent_notify_attention_panes"
done_panes_option="@agent_notify_done_panes"
all_panes_option="@agent_notify_all_panes"
lock_key="$(printf '%s' "$CURRENT_DIR" | cksum | awk '{print $1}')"
lock_dir="/tmp/tmux-agent-notify-${lock_key}.lock"
separator=$'\037'

pane_agent_option="@agent_notify_is_agent"
pane_kind_label_option="@agent_notify_pane_kind_label"
pane_state_option="@agent_notify_pane_state"
pane_state_badge_option="@agent_notify_pane_state_badge"
pane_label_option="@agent_notify_pane_label"
window_has_agents_option="@agent_notify_window_has_agents"
window_summary_option="@agent_notify_window_summary"
session_has_agents_option="@agent_notify_session_has_agents"
session_summary_option="@agent_notify_session_summary"

agent_process_pattern=""
attention_patterns=""
done_prompt_patterns=""
capture_lines=""

escape_applescript() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

send_notification() {
  local title="$1"
  local message="$2"

  if command -v osascript >/dev/null 2>&1; then
    local escaped_title escaped_message
    escaped_title="$(escape_applescript "$title")"
    escaped_message="$(escape_applescript "$message")"
    osascript -e "display notification \"$escaped_message\" with title \"$escaped_title\"" >/dev/null 2>&1 || true
  else
    tmux display-message "${title}: ${message}" >/dev/null 2>&1 || true
  fi
}

status_text() {
  local attention_count="$1"
  local done_count="$2"
  local text=""

  if [ "$attention_count" -eq 0 ] && [ "$done_count" -eq 0 ]; then
    printf '\n'
    return
  fi

  text="#[fg=colour39 bold]AI#[default]"

  if [ "$attention_count" -gt 0 ]; then
    text="${text} #[fg=colour214 bold]!${attention_count}#[default]"
  fi

  if [ "$done_count" -gt 0 ]; then
    text="${text} #[fg=colour42]D${done_count}#[default]"
  fi

  printf '%s\n' "$text"
}

tail_nonempty_lines() {
  local text="$1"
  local limit="$2"

  printf '%s\n' "$text" | awk -v limit="$limit" '
    NF { lines[++count] = $0 }
    END {
      start = count - limit + 1
      if (start < 1) {
        start = 1
      }
      for (i = start; i <= count; i++) {
        print lines[i]
      }
    }
  '
}

matches_attention() {
  local text="$1"
  local tail_text

  if [ -z "${text//[[:space:]]/}" ]; then
    return 1
  fi

  tail_text="$(tail_nonempty_lines "$text" "12")"
  printf '%s\n' "$tail_text" | grep -Eiq "$attention_patterns"
}

matches_done_prompt() {
  local prompt_tail
  prompt_tail="$(tail_nonempty_lines "$1" "3")"

  if [ -z "${prompt_tail//[[:space:]]/}" ]; then
    return 1
  fi

  printf '%s\n' "$prompt_tail" | grep -Eiq "$done_prompt_patterns"
}

classify_state() {
  local text="$1"

  if matches_attention "$text"; then
    printf 'attention\n'
    return
  fi

  if matches_done_prompt "$text"; then
    printf 'done\n'
    return
  fi

  printf 'busy\n'
}

capture_signature() {
  printf '%s\n' "$1" | tail -n 25 | cksum | awk '{print $1 ":" $2}'
}

should_notify_for_pane() {
  local pane_active="$1"
  local window_active="$2"
  local session_attached="$3"

  if [ "$session_attached" -gt 0 ] && [ "$window_active" -eq 1 ] && [ "$pane_active" -eq 1 ]; then
    return 1
  fi

  return 0
}

is_actionable_pane() {
  should_notify_for_pane "$1" "$2" "$3"
}

display_state_for_pane() {
  local state="$1"
  local pane_active="$2"
  local window_active="$3"
  local session_attached="$4"

  if should_notify_for_pane "$pane_active" "$window_active" "$session_attached"; then
    printf '%s\n' "$state"
  else
    printf 'current\n'
  fi
}

pane_count_word() {
  if [ "$1" -eq 1 ]; then
    printf 'pane'
  else
    printf 'panes'
  fi
}

kind_label() {
  case "$1" in
    codex) printf 'Codex\n' ;;
    claude) printf 'Claude\n' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

pane_state_badge() {
  case "$1" in
    attention) printf '#[fg=colour214 bold]! input#[default]\n' ;;
    done) printf '#[fg=colour42]D waiting#[default]\n' ;;
    busy) printf '#[fg=colour245]B busy#[default]\n' ;;
    current) printf '#[fg=colour39 bold]C current#[default]\n' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

summary_badge() {
  local attention_count="$1"
  local done_count="$2"
  local busy_count="$3"
  local current_count="$4"
  local pane_count="$5"
  local text=""

  if [ "$attention_count" -gt 0 ]; then
    text="${text} #[fg=colour214 bold]!${attention_count}#[default]"
  fi

  if [ "$done_count" -gt 0 ]; then
    text="${text} #[fg=colour42]D${done_count}#[default]"
  fi

  if [ "$busy_count" -gt 0 ]; then
    text="${text} #[fg=colour245]B${busy_count}#[default]"
  fi

  if [ "$current_count" -gt 0 ]; then
    text="${text} #[fg=colour39 bold]C${current_count}#[default]"
  fi

  text="${text} #[fg=colour244](${pane_count} $(pane_count_word "$pane_count"))#[default]"
  trim_whitespace "$text"
}

pane_item_label() {
  local window_name="$1"
  local pane_title="$2"
  local pane_current_path="$3"
  local basename=""
  local label=""

  if [ -n "$pane_current_path" ]; then
    basename="${pane_current_path##*/}"
  fi

  if [ -n "$window_name" ]; then
    label="$window_name"
  elif [ -n "$basename" ]; then
    label="$basename"
  fi

  if [ -n "$pane_title" ] && [ "$pane_title" != "$window_name" ]; then
    if [ -n "$label" ]; then
      label="${label} - ${pane_title}"
    else
      label="$pane_title"
    fi
  fi

  if [ -z "$label" ]; then
    label="$pane_current_path"
  fi

  printf '%s\n' "$label"
}

pane_label() {
  local session_name="$1"
  local window_index="$2"
  local pane_index="$3"
  local pane_title="$4"
  local label="${session_name}:${window_index}.${pane_index}"

  if [ -n "$pane_title" ]; then
    printf '%s (%s)\n' "$label" "$pane_title"
  else
    printf '%s\n' "$label"
  fi
}

notify_for_state() {
  local kind="$1"
  local state="$2"
  local label="$3"
  local title=""

  case "$kind" in
    codex)
      title="Codex"
      ;;
    claude)
      title="Claude"
      ;;
    *)
      title="$kind"
      ;;
  esac

  case "$state" in
    attention)
      send_notification "$title" "${label} needs input"
      ;;
    done)
      send_notification "$title" "${label} is waiting for you"
      ;;
  esac
}

clear_tree_metadata() {
  local target
  local previous_panes previous_windows previous_sessions

  previous_panes="$(tmux list-panes -a -f "#{==:#{${pane_agent_option}},1}" -F '#{pane_id}' 2>/dev/null || true)"
  previous_windows="$(tmux list-windows -a -f "#{==:#{${window_has_agents_option}},1}" -F '#{session_name}:#{window_index}' 2>/dev/null || true)"
  previous_sessions="$(tmux list-sessions -f "#{==:#{${session_has_agents_option}},1}" -F '#{session_name}' 2>/dev/null || true)"

  while IFS= read -r target; do
    if [ -n "$target" ]; then
      set_tmux_target_option pane "$target" "$pane_agent_option" "0"
    fi
  done <<EOF
$previous_panes
EOF

  while IFS= read -r target; do
    if [ -n "$target" ]; then
      set_tmux_target_option window "$target" "$window_has_agents_option" "0"
    fi
  done <<EOF
$previous_windows
EOF

  while IFS= read -r target; do
    if [ -n "$target" ]; then
      set_tmux_target_option session "$target" "$session_has_agents_option" "0"
    fi
  done <<EOF
$previous_sessions
EOF
}

apply_tree_metadata() {
  local agent_rows="$1"
  local aggregate_rows=""
  local summary_rows=""
  local pane_id kind state display_state session_name window_index pane_index pane_title pane_current_path window_name

  clear_tree_metadata

  if [ -z "$agent_rows" ]; then
    return
  fi

  while IFS="$separator" read -r pane_id kind state display_state session_name window_index pane_index pane_title pane_current_path window_name; do
    if [ -z "${pane_id:-}" ]; then
      continue
    fi

    set_tmux_target_option pane "$pane_id" "$pane_agent_option" "1"
    set_tmux_target_option pane "$pane_id" "$pane_kind_label_option" "$(kind_label "$kind")"
    set_tmux_target_option pane "$pane_id" "$pane_state_option" "$display_state"
    set_tmux_target_option pane "$pane_id" "$pane_state_badge_option" "$(pane_state_badge "$display_state")"
    set_tmux_target_option pane "$pane_id" "$pane_label_option" "$(pane_item_label "$window_name" "$pane_title" "$pane_current_path")"

    aggregate_rows="${aggregate_rows}${session_name}${separator}${window_index}${separator}${display_state}"$'\n'
  done <<EOF
$agent_rows
EOF

  summary_rows="$(
    printf '%s' "$aggregate_rows" | awk -F "$separator" -v OFS="$separator" '
      {
        session_key = "session" SUBSEP $1
        window_key = "window" SUBSEP $1 ":" $2
        state = $3

        if (!(session_key in seen)) {
          seen[session_key] = 1
          order[++count] = session_key
        }

        if (!(window_key in seen)) {
          seen[window_key] = 1
          order[++count] = window_key
        }

        total[session_key]++
        total[window_key]++

        if (state == "attention") {
          attention[session_key]++
          attention[window_key]++
        } else if (state == "done") {
          waiting[session_key]++
          waiting[window_key]++
        } else if (state == "busy") {
          busy[session_key]++
          busy[window_key]++
        } else if (state == "current") {
          current[session_key]++
          current[window_key]++
        }
      }
      END {
        for (i = 1; i <= count; i++) {
          split(order[i], parts, SUBSEP)
          scope = parts[1]
          key = parts[2]
          print scope, key, attention[order[i]] + 0, waiting[order[i]] + 0, busy[order[i]] + 0, current[order[i]] + 0, total[order[i]] + 0
        }
      }
    '
  )"

  while IFS="$separator" read -r scope target attention_count done_count busy_count current_count pane_count; do
    local summary

    if [ -z "${scope:-}" ] || [ -z "${target:-}" ]; then
      continue
    fi

    summary="$(summary_badge "$attention_count" "$done_count" "$busy_count" "$current_count" "$pane_count")"

    case "$scope" in
      session)
        set_tmux_target_option session "$target" "$session_has_agents_option" "1"
        set_tmux_target_option session "$target" "$session_summary_option" "$summary"
        ;;
      window)
        set_tmux_target_option window "$target" "$window_has_agents_option" "1"
        set_tmux_target_option window "$target" "$window_summary_option" "$summary"
        ;;
    esac
  done <<EOF
$summary_rows
EOF
}

run_loop() {
  local first_pass="1"

  while true; do
    local interval
    interval="$(get_tmux_option "@agent_notify_interval" "5")"
    capture_lines="$(get_tmux_option "@agent_notify_capture_lines" "80")"
    agent_process_pattern="$(get_tmux_option "@agent_notify_process_pattern" "")"
    attention_patterns="$(get_tmux_option "@agent_notify_attention_patterns" "")"
    done_prompt_patterns="$(get_tmux_option "@agent_notify_done_prompt_patterns" "")"

    local panes_output
    if ! panes_output="$(tmux list-panes -a -F "#{pane_id}${separator}#{pane_pid}${separator}#{session_name}${separator}#{window_index}${separator}#{pane_index}${separator}#{pane_active}${separator}#{window_active}${separator}#{session_attached}${separator}#{pane_title}${separator}#{pane_current_path}${separator}#{window_name}" 2>/dev/null)"; then
      exit 0
    fi

    local attention_panes=""
    local done_panes=""
    local all_panes=""
    local attention_count=0
    local done_count=0
    local agent_rows=""

    while IFS="$separator" read -r pane_id pane_pid session_name window_index pane_index pane_active window_active session_attached pane_title pane_current_path window_name; do
      if [ -z "${pane_id:-}" ]; then
        continue
      fi

      local kind
      if ! kind="$(agent_kind_for_pane "$pane_pid" "$pane_title" "$agent_process_pattern")"; then
        continue
      fi

      local pane_text
      pane_text="$(tmux capture-pane -p -t "$pane_id" -S "-${capture_lines}" 2>/dev/null || true)"

      local state
      state="$(classify_state "$pane_text")"

      local display_state
      display_state="$(display_state_for_pane "$state" "$pane_active" "$window_active" "$session_attached")"

      local key
      key="$(pane_key "$pane_id")"

      local signature
      signature="${state}|$(capture_signature "$pane_text")"

      local previous_signature
      previous_signature="$(get_tmux_option "@agent_notify_signature_${key}" "")"
      set_tmux_option "@agent_notify_signature_${key}" "$signature"
      set_tmux_option "@agent_notify_state_${key}" "$state"

      all_panes="${all_panes} ${pane_id}"
      agent_rows="${agent_rows}${pane_id}${separator}${kind}${separator}${state}${separator}${display_state}${separator}${session_name}${separator}${window_index}${separator}${pane_index}${separator}${pane_title}${separator}${pane_current_path}${separator}${window_name}"$'\n'

      if is_actionable_pane "$pane_active" "$window_active" "$session_attached"; then
        case "$state" in
          attention)
            attention_panes="${attention_panes} ${pane_id}"
            attention_count=$((attention_count + 1))
            ;;
          done)
            done_panes="${done_panes} ${pane_id}"
            done_count=$((done_count + 1))
            ;;
        esac
      fi

      if [ "$first_pass" = "1" ]; then
        continue
      fi

      if [ "$signature" = "$previous_signature" ]; then
        continue
      fi

      if [ "$state" != "attention" ] && [ "$state" != "done" ]; then
        continue
      fi

      if ! is_actionable_pane "$pane_active" "$window_active" "$session_attached"; then
        continue
      fi

      notify_for_state "$kind" "$state" "$(pane_label "$session_name" "$window_index" "$pane_index" "$pane_title")"
    done <<EOF
$panes_output
EOF

    apply_tree_metadata "$agent_rows"

    local trimmed_attention trimmed_done trimmed_all new_status previous_status
    trimmed_attention="$(trim_whitespace "$attention_panes")"
    trimmed_done="$(trim_whitespace "$done_panes")"
    trimmed_all="$(trim_whitespace "$all_panes")"
    new_status="$(status_text "$attention_count" "$done_count")"
    previous_status="$(get_tmux_option "$status_option" "")"

    set_tmux_option "$attention_panes_option" "$trimmed_attention"
    set_tmux_option "$done_panes_option" "$trimmed_done"
    set_tmux_option "$all_panes_option" "$trimmed_all"
    set_tmux_option "$status_option" "$new_status"

    if [ "$new_status" != "$previous_status" ]; then
      tmux refresh-client -S >/dev/null 2>&1 || true
    fi

    first_pass="0"
    sleep "$interval"
  done
}

start_monitor() {
  "$CURRENT_DIR/monitor.sh" run >/dev/null 2>&1 &
}

acquire_run_lock() {
  if mkdir "$lock_dir" >/dev/null 2>&1; then
    printf '%s\n' "$$" > "${lock_dir}/pid"
    set_tmux_option "$monitor_pid_option" "$$"
    return 0
  fi

  if [ -f "${lock_dir}/pid" ]; then
    local existing_pid
    existing_pid="$(cat "${lock_dir}/pid" 2>/dev/null || true)"

    if [ -n "$existing_pid" ] && kill -0 "$existing_pid" >/dev/null 2>&1; then
      set_tmux_option "$monitor_pid_option" "$existing_pid"
      return 1
    fi
  fi

  rm -f "${lock_dir}/pid" >/dev/null 2>&1 || true
  rmdir "$lock_dir" >/dev/null 2>&1 || true

  if mkdir "$lock_dir" >/dev/null 2>&1; then
    printf '%s\n' "$$" > "${lock_dir}/pid"
    set_tmux_option "$monitor_pid_option" "$$"
    return 0
  fi

  return 1
}

release_run_lock() {
  local tracked_pid
  tracked_pid="$(cat "${lock_dir}/pid" 2>/dev/null || true)"

  if [ "$tracked_pid" = "$$" ]; then
    rm -f "${lock_dir}/pid" >/dev/null 2>&1 || true
    rmdir "$lock_dir" >/dev/null 2>&1 || true
  fi

  clear_tree_metadata
  unset_tmux_option "$monitor_pid_option"
  set_tmux_option "$status_option" ""
  set_tmux_option "$attention_panes_option" ""
  set_tmux_option "$done_panes_option" ""
  set_tmux_option "$all_panes_option" ""
}

stop_monitor() {
  local existing_pid=""

  if [ -f "${lock_dir}/pid" ]; then
    existing_pid="$(cat "${lock_dir}/pid" 2>/dev/null || true)"
  else
    existing_pid="$(get_tmux_option "$monitor_pid_option" "")"
  fi

  if [ -n "$existing_pid" ]; then
    kill "$existing_pid" >/dev/null 2>&1 || true
  fi

  rm -f "${lock_dir}/pid" >/dev/null 2>&1 || true
  rmdir "$lock_dir" >/dev/null 2>&1 || true
  clear_tree_metadata
  unset_tmux_option "$monitor_pid_option"
  set_tmux_option "$status_option" ""
  set_tmux_option "$attention_panes_option" ""
  set_tmux_option "$done_panes_option" ""
  set_tmux_option "$all_panes_option" ""
}

case "${1:-run}" in
  start)
    start_monitor
    ;;
  stop)
    stop_monitor
    ;;
  run)
    if ! acquire_run_lock; then
      exit 0
    fi
    trap 'release_run_lock' EXIT
    run_loop
    ;;
  *)
    printf 'Usage: %s [start|stop|run]\n' "$0" >&2
    exit 1
    ;;
esac
