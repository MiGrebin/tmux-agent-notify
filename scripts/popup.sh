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
    current) printf 'current' ;;
    *) printf '%s' "$1" ;;
  esac
}

state_rank() {
  case "$1" in
    attention) printf '0' ;;
    done) printf '1' ;;
    busy) printf '2' ;;
    *) printf '9' ;;
  esac
}

is_current_row() {
  local pane_active="$1"
  local window_active="$2"
  local session_attached="$3"

  if [ "$session_attached" -gt 0 ] && [ "$window_active" -eq 1 ] && [ "$pane_active" -eq 1 ]; then
    return 0
  fi

  return 1
}

display_state_label() {
  local state="$1"
  local pane_active="$2"
  local window_active="$3"
  local session_attached="$4"

  if is_current_row "$pane_active" "$window_active" "$session_attached"; then
    state_label current
    return
  fi

  state_label "$state"
}

pane_word() {
  if [ "$1" -eq 1 ]; then
    printf 'pane'
  else
    printf 'panes'
  fi
}

project_word() {
  if [ "$1" -eq 1 ]; then
    printf 'project'
  else
    printf 'projects'
  fi
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

sort_rows() {
  local current_session
  local sorted_rows
  local row

  if [ "${#rows[@]}" -eq 0 ]; then
    return
  fi

  current_session="$(tmux display-message -p '#S' 2>/dev/null || true)"

  sorted_rows="$(
    for row in "${rows[@]}"; do
      local pane_id kind state session_name window_index pane_index pane_title pane_current_path pane_active window_active session_attached
      local session_order

      IFS="$separator" read -r pane_id kind state session_name window_index pane_index pane_title pane_current_path pane_active window_active session_attached <<< "$row"

      session_order="1"
      if [ "$session_name" = "$current_session" ]; then
        session_order="0"
      fi

      printf '%s\t%s\t%s\t%05d\t%05d\t%s\n' \
        "$session_order" \
        "$(printf '%s' "$session_name" | tr '[:upper:]' '[:lower:]')" \
        "$(state_rank "$state")" \
        "$window_index" \
        "$pane_index" \
        "$row"
    done | LC_ALL=C sort -t $'\t' -k1,1n -k2,2 -k3,3n -k4,4n -k5,5n | cut -f6-
  )"

  rows=()
  while IFS= read -r row; do
    if [ -n "$row" ]; then
      rows+=("$row")
    fi
  done <<EOF
$sorted_rows
EOF
}

collect_rows() {
  local process_pattern
  local panes_output
  local previous_selected_pane=""
  local i

  if [ "${#rows[@]}" -gt 0 ] && [ "$selected_index" -lt "${#rows[@]}" ]; then
    IFS="$separator" read -r previous_selected_pane _ <<< "${rows[$selected_index]}"
  fi

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

  sort_rows

  if [ "${#rows[@]}" -eq 0 ]; then
    selected_index=0
    return
  fi

  if [ -n "$previous_selected_pane" ]; then
    for i in "${!rows[@]}"; do
      local pane_id
      IFS="$separator" read -r pane_id _ <<< "${rows[$i]}"
      if [ "$pane_id" = "$previous_selected_pane" ]; then
        selected_index="$i"
        return
      fi
    done
  fi

  if [ "$selected_index" -ge "${#rows[@]}" ]; then
    selected_index=$(( ${#rows[@]} - 1 ))
  fi
}

project_summary() {
  local project_name="$1"
  local attention_count=0
  local done_count=0
  local busy_count=0
  local current_count=0
  local pane_count=0
  local is_current_project=0
  local row

  for row in "${rows[@]}"; do
    local pane_id kind state session_name window_index pane_index pane_title pane_current_path pane_active window_active session_attached

    IFS="$separator" read -r pane_id kind state session_name window_index pane_index pane_title pane_current_path pane_active window_active session_attached <<< "$row"

    if [ "$session_name" != "$project_name" ]; then
      continue
    fi

    pane_count=$((pane_count + 1))

    if is_current_row "$pane_active" "$window_active" "$session_attached"; then
      current_count=$((current_count + 1))
      is_current_project=1
      continue
    fi

    case "$state" in
      attention) attention_count=$((attention_count + 1)) ;;
      done) done_count=$((done_count + 1)) ;;
      busy) busy_count=$((busy_count + 1)) ;;
    esac
  done

  printf '%s%s%s%s%s%s%s%s%s%s%s\n' \
    "$attention_count" \
    "$separator" \
    "$done_count" \
    "$separator" \
    "$busy_count" \
    "$separator" \
    "$current_count" \
    "$separator" \
    "$pane_count" \
    "$separator" \
    "$is_current_project"
}

global_summary_line() {
  local project_count=0
  local attention_count=0
  local done_count=0
  local busy_count=0
  local current_count=0
  local previous_project=""
  local row

  for row in "${rows[@]}"; do
    local pane_id kind state session_name window_index pane_index pane_title pane_current_path pane_active window_active session_attached

    IFS="$separator" read -r pane_id kind state session_name window_index pane_index pane_title pane_current_path pane_active window_active session_attached <<< "$row"

    if [ "$session_name" != "$previous_project" ]; then
      project_count=$((project_count + 1))
      previous_project="$session_name"
    fi

    if is_current_row "$pane_active" "$window_active" "$session_attached"; then
      current_count=$((current_count + 1))
      continue
    fi

    case "$state" in
      attention) attention_count=$((attention_count + 1)) ;;
      done) done_count=$((done_count + 1)) ;;
      busy) busy_count=$((busy_count + 1)) ;;
    esac
  done

  printf '%s %s  !%s needs input  D%s waiting  B%s busy\n' \
    "$project_count" \
    "$(project_word "$project_count")" \
    "$attention_count" \
    "$done_count" \
    "$busy_count"

  if [ "$current_count" -gt 0 ]; then
    printf 'C%s current\n' "$current_count"
  fi
}

render_project_header() {
  local project_name="$1"
  local summary
  local attention_count done_count busy_count current_count pane_count is_current_project
  local current_suffix

  summary="$(project_summary "$project_name")"
  IFS="$separator" read -r attention_count done_count busy_count current_count pane_count is_current_project <<< "$summary"

  current_suffix=""
  if [ "$is_current_project" -eq 1 ]; then
    current_suffix=" [current]"
  fi

  printf 'Project: %s%s  !%s D%s B%s C%s  %s %s\n' \
    "$project_name" \
    "$current_suffix" \
    "$attention_count" \
    "$done_count" \
    "$busy_count" \
    "$current_count" \
    "$pane_count" \
    "$(pane_word "$pane_count")"
  printf '   %-3s %-11s %-7s %-6s %s\n' '#' 'State' 'Agent' 'Win' 'Title'
}

render_rows() {
  local i
  local previous_project=""

  printf 'Agent Sessions\n\n'
  printf 'j/k move  Enter jump  1-9 direct jump  r refresh  q quit\n\n'

  if [ "${#rows[@]}" -eq 0 ]; then
    printf 'No Codex or Claude panes found.\n'
    return
  fi

  printf '%s\n\n' "$(global_summary_line)"

  for i in "${!rows[@]}"; do
    local pane_id kind state session_name window_index pane_index pane_title pane_current_path pane_active window_active session_attached
    local marker target title label

    IFS="$separator" read -r pane_id kind state session_name window_index pane_index pane_title pane_current_path pane_active window_active session_attached <<< "${rows[$i]}"

    if [ "$session_name" != "$previous_project" ]; then
      if [ -n "$previous_project" ]; then
        printf '\n'
      fi
      render_project_header "$session_name"
      previous_project="$session_name"
    fi

    marker=' '
    if [ "$i" -eq "$selected_index" ]; then
      marker='>'
    fi

    label="$(display_state_label "$state" "$pane_active" "$window_active" "$session_attached")"

    target="${window_index}.${pane_index}"
    title="$pane_title"
    if [ -z "$title" ]; then
      title="$pane_current_path"
    fi

    printf '%-2s %-3s %-11s %-7s %-6s %s\n' \
      "$marker" \
      "$((i + 1))" \
      "$(truncate_text "$label" 11)" \
      "$kind" \
      "$(truncate_text "$target" 6)" \
      "$(truncate_text "$title" 52)"
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
  if is_current_row "$pane_active" "$window_active" "$session_attached"; then
    current_line='yes'
  fi

  printf 'Selected: %s\n' "$pane_id"
  printf 'Project:  %s\n' "$session_name"
  printf 'Target:   %s:%s.%s\n' "$session_name" "$window_index" "$pane_index"
  printf 'State:    %s\n' "$(display_state_label "$state" "$pane_active" "$window_active" "$session_attached")"
  printf 'Agent:    %s\n' "$kind"
  printf 'Current:  %s\n' "$current_line"
  if [ -n "$pane_title" ]; then
    printf 'Title:    %s\n' "$pane_title"
  fi
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
