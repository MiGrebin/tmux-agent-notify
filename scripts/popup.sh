#!/usr/bin/env bash

set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CURRENT_DIR/helpers.sh"

separator=$'\037'
selected_index=0
rows=()

state_label() {
  case "$1" in
    attention) printf 'needs-input' ;;
    done) printf 'waiting' ;;
    busy) printf 'busy' ;;
    *) printf '%s' "$1" ;;
  esac
}

truncate_text() {
  local text="$1"
  local width="$2"

  if [ "${#text}" -le "$width" ]; then
    printf '%s' "$text"
  else
    printf '%s...' "${text:0:$((width - 3))}"
  fi
}

collect_rows() {
  local process_pattern
  local panes_output
  process_pattern="$(get_tmux_option "@agent_notify_process_pattern" '(/bin/codex|/@openai/codex|(^|[[:space:]/])claude([[:space:]]|$)|/@anthropic-ai/claude-code)')"

  rows=()
  panes_output="$(tmux list-panes -a -F "#{pane_id}${separator}#{pane_pid}${separator}#{session_name}${separator}#{window_index}${separator}#{pane_index}${separator}#{pane_active}${separator}#{window_active}${separator}#{session_attached}${separator}#{pane_title}${separator}#{pane_current_path}" 2>/dev/null || true)"

  while IFS="$separator" read -r pane_id pane_pid session_name window_index pane_index pane_active window_active session_attached pane_title pane_current_path; do
    local kind key state

    if [ -z "${pane_id:-}" ]; then
      continue
    fi

    if ! kind="$(agent_kind_for_pane "$pane_pid" "$pane_title" "$process_pattern")"; then
      continue
    fi

    key="$(pane_key "$pane_id")"
    state="$(get_tmux_option "@agent_notify_state_${key}" "busy")"

    rows+=("${pane_id}${separator}${kind}${separator}${state}${separator}${session_name}${separator}${window_index}${separator}${pane_index}${separator}${pane_title}${separator}${pane_current_path}${separator}${pane_active}${separator}${window_active}${separator}${session_attached}")
  done <<EOF
$panes_output
EOF

  if [ "${#rows[@]}" -eq 0 ]; then
    selected_index=0
    return
  fi

  if [ "$selected_index" -ge "${#rows[@]}" ]; then
    selected_index=$(( ${#rows[@]} - 1 ))
  fi
}

render_rows() {
  local i
  printf 'Agent Sessions\n\n'
  printf 'j/k move  Enter jump  1-9 direct jump  r refresh  q quit\n\n'

  if [ "${#rows[@]}" -eq 0 ]; then
    printf 'No Codex or Claude panes found.\n'
    return
  fi

  printf '%-2s %-3s %-11s %-7s %-18s %s\n' '' '#' 'State' 'Agent' 'Target' 'Title'

  for i in "${!rows[@]}"; do
    local pane_id kind state session_name window_index pane_index pane_title pane_current_path pane_active window_active session_attached
    local marker target title label

    IFS="$separator" read -r pane_id kind state session_name window_index pane_index pane_title pane_current_path pane_active window_active session_attached <<< "${rows[$i]}"

    marker=' '
    if [ "$i" -eq "$selected_index" ]; then
      marker='>'
    fi

    label="$(state_label "$state")"
    if [ "$session_attached" -gt 0 ] && [ "$window_active" -eq 1 ] && [ "$pane_active" -eq 1 ]; then
      label='current'
    fi

    target="${session_name}:${window_index}.${pane_index}"
    title="$pane_title"
    if [ -z "$title" ]; then
      title="$pane_current_path"
    fi

    printf '%-2s %-3s %-11s %-7s %-18s %s\n' "$marker" "$((i + 1))" "$(truncate_text "$label" 11)" "$kind" "$(truncate_text "$target" 18)" "$(truncate_text "$title" 44)"
  done

  printf '\n'
  render_selected_details
}

render_selected_details() {
  local pane_id kind state session_name window_index pane_index pane_title pane_current_path pane_active window_active session_attached
  local current_line

  if [ "${#rows[@]}" -eq 0 ]; then
    return
  fi

  IFS="$separator" read -r pane_id kind state session_name window_index pane_index pane_title pane_current_path pane_active window_active session_attached <<< "${rows[$selected_index]}"

  current_line='no'
  if [ "$session_attached" -gt 0 ] && [ "$window_active" -eq 1 ] && [ "$pane_active" -eq 1 ]; then
    current_line='yes'
  fi

  printf 'Selected: %s %s:%s.%s\n' "$kind" "$session_name" "$window_index" "$pane_index"
  printf 'State:    %s\n' "$(state_label "$state")"
  printf 'Current:  %s\n' "$current_line"
  printf 'Pane:     %s\n' "$pane_id"
  printf 'Path:     %s\n' "$pane_current_path"
}

render_screen() {
  printf '\033[H\033[2J'
  render_rows
}

move_selection() {
  local direction="$1"

  if [ "${#rows[@]}" -eq 0 ]; then
    return
  fi

  case "$direction" in
    down)
      if [ "$selected_index" -lt $(( ${#rows[@]} - 1 )) ]; then
        selected_index=$((selected_index + 1))
      fi
      ;;
    up)
      if [ "$selected_index" -gt 0 ]; then
        selected_index=$((selected_index - 1))
      fi
      ;;
    first)
      selected_index=0
      ;;
    last)
      selected_index=$(( ${#rows[@]} - 1 ))
      ;;
  esac
}

jump_to_selected() {
  local pane_id

  if [ "${#rows[@]}" -eq 0 ]; then
    return
  fi

  IFS="$separator" read -r pane_id _ <<< "${rows[$selected_index]}"

  if switch_to_pane "$pane_id"; then
    exit 0
  fi

  collect_rows
}

handle_key() {
  local key="$1"
  local extra=''

  case "$key" in
    q) exit 0 ;;
    r) collect_rows ;;
    j) move_selection down ;;
    k) move_selection up ;;
    g) move_selection first ;;
    G) move_selection last ;;
    '')
      jump_to_selected
      ;;
    [1-9])
      if [ "$key" -le "${#rows[@]}" ]; then
        selected_index=$((key - 1))
        jump_to_selected
      fi
      ;;
    $'\e')
      if read -rsn2 -t 0.05 extra; then
        case "$extra" in
          '[A') move_selection up ;;
          '[B') move_selection down ;;
        esac
      else
        exit 0
      fi
      ;;
  esac
}

main() {
  collect_rows

  while true; do
    local key=''
    render_screen
    if read -rsn1 -t 1 key; then
      handle_key "$key"
    else
      collect_rows
    fi
  done
}

main
