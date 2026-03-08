#!/usr/bin/env bash

set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CURRENT_DIR/helpers.sh"

separator=$'\037'
selected_index=0
rows=()
last_screen=""

ansi_reset=$'\033[0m'
ansi_bold=$'\033[1m'
ansi_dim=$'\033[2m'
ansi_yellow=$'\033[33m'
ansi_green=$'\033[32m'
ansi_cyan=$'\033[36m'
ansi_gray=$'\033[90m'

repeat_char() {
  local char="$1"
  local count="$2"

  if [ "$count" -le 0 ]; then
    printf '\n'
    return
  fi

  printf '%*s\n' "$count" '' | tr ' ' "$char"
}

state_rank() {
  case "$1" in
    attention) printf '0' ;;
    done) printf '1' ;;
    busy) printf '2' ;;
    current) printf '3' ;;
    *) printf '9' ;;
  esac
}

state_badge_plain() {
  case "$1" in
    attention) printf '[! input]' ;;
    done) printf '[D wait]' ;;
    busy) printf '[B busy]' ;;
    current) printf '[C here]' ;;
    *) printf '[%s]' "$1" ;;
  esac
}

state_badge() {
  local state="$1"
  local text

  text="$(state_badge_plain "$state")"

  case "$state" in
    attention) printf '%s%s%s' "$ansi_yellow" "$text" "$ansi_reset" ;;
    done) printf '%s%s%s' "$ansi_green" "$text" "$ansi_reset" ;;
    current) printf '%s%s%s' "$ansi_cyan" "$text" "$ansi_reset" ;;
    *) printf '%s%s%s' "$ansi_gray" "$text" "$ansi_reset" ;;
  esac
}

project_word() {
  if [ "$1" -eq 1 ]; then
    printf 'project'
  else
    printf 'projects'
  fi
}

pane_word() {
  if [ "$1" -eq 1 ]; then
    printf 'pane'
  else
    printf 'panes'
  fi
}

truncate_text() {
  local text="$1"
  local width="$2"

  if [ "$width" -le 3 ]; then
    printf '%.*s' "$width" "$text"
    return
  fi

  if [ "${#text}" -le "$width" ]; then
    printf '%s' "$text"
  else
    printf '%s...' "${text:0:$((width - 3))}"
  fi
}

screen_width() {
  local width
  width="$(tput cols 2>/dev/null || printf '80')"

  if ! [ "$width" -ge 40 ] 2>/dev/null; then
    width=80
  fi

  printf '%s\n' "$width"
}

collect_rows() {
  local panes_output
  local previous_selected_pane=""
  local i

  if [ "${#rows[@]}" -gt 0 ] && [ "$selected_index" -lt "${#rows[@]}" ]; then
    IFS="$separator" read -r previous_selected_pane _ <<< "${rows[$selected_index]}"
  fi

  rows=()
  panes_output="$(tmux list-panes -a -f '#{==:#{@agent_notify_is_agent},1}' -F "#{pane_id}${separator}#{@agent_notify_pane_kind_label}${separator}#{@agent_notify_pane_state}${separator}#{session_name}${separator}#{window_index}${separator}#{pane_index}${separator}#{@agent_notify_pane_label}${separator}#{pane_current_path}" 2>/dev/null || true)"

  while IFS="$separator" read -r pane_id kind state session_name window_index pane_index pane_label pane_current_path; do
    if [ -z "${pane_id:-}" ]; then
      continue
    fi

    rows+=("${pane_id}${separator}${kind}${separator}${state}${separator}${session_name}${separator}${window_index}${separator}${pane_index}${separator}${pane_label}${separator}${pane_current_path}")
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
      local pane_id kind state session_name window_index pane_index pane_label pane_current_path
      local session_order

      IFS="$separator" read -r pane_id kind state session_name window_index pane_index pane_label pane_current_path <<< "$row"

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

project_summary() {
  local project_name="$1"
  local attention_count=0
  local done_count=0
  local busy_count=0
  local current_count=0
  local pane_count=0
  local is_current_project=0
  local row
  local current_session

  current_session="$(tmux display-message -p '#S' 2>/dev/null || true)"

  for row in "${rows[@]}"; do
    local pane_id kind state session_name window_index pane_index pane_label pane_current_path

    IFS="$separator" read -r pane_id kind state session_name window_index pane_index pane_label pane_current_path <<< "$row"

    if [ "$session_name" != "$project_name" ]; then
      continue
    fi

    pane_count=$((pane_count + 1))

    if [ "$session_name" = "$current_session" ]; then
      is_current_project=1
    fi

    case "$state" in
      attention) attention_count=$((attention_count + 1)) ;;
      done) done_count=$((done_count + 1)) ;;
      busy) busy_count=$((busy_count + 1)) ;;
      current) current_count=$((current_count + 1)) ;;
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

project_summary_text() {
  local project_name="$1"
  local summary
  local attention_count done_count busy_count current_count pane_count is_current_project

  summary="$(project_summary "$project_name")"
  IFS="$separator" read -r attention_count done_count busy_count current_count pane_count is_current_project <<< "$summary"

  printf '%s %s | !%s input | D%s waiting | B%s busy | C%s current\n' \
    "$pane_count" \
    "$(pane_word "$pane_count")" \
    "$attention_count" \
    "$done_count" \
    "$busy_count" \
    "$current_count"
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
    local pane_id kind state session_name window_index pane_index pane_label pane_current_path

    IFS="$separator" read -r pane_id kind state session_name window_index pane_index pane_label pane_current_path <<< "$row"

    if [ "$session_name" != "$previous_project" ]; then
      project_count=$((project_count + 1))
      previous_project="$session_name"
    fi

    case "$state" in
      attention) attention_count=$((attention_count + 1)) ;;
      done) done_count=$((done_count + 1)) ;;
      busy) busy_count=$((busy_count + 1)) ;;
      current) current_count=$((current_count + 1)) ;;
    esac
  done

  printf '%s %s | !%s input | D%s waiting | B%s busy' \
    "$project_count" \
    "$(project_word "$project_count")" \
    "$attention_count" \
    "$done_count" \
    "$busy_count"

  if [ "$current_count" -gt 0 ]; then
    printf ' | C%s current' "$current_count"
  fi

  printf '\n'
}

render_project_header() {
  local project_name="$1"
  local cols divider summary_line
  local summary
  local attention_count done_count busy_count current_count pane_count is_current_project
  local current_suffix

  cols="$(screen_width)"
  divider="$(repeat_char '=' "$cols")"
  summary="$(project_summary "$project_name")"
  IFS="$separator" read -r attention_count done_count busy_count current_count pane_count is_current_project <<< "$summary"
  summary_line="$(project_summary_text "$project_name")"

  current_suffix=""
  if [ "$is_current_project" -eq 1 ]; then
    current_suffix=" [current]"
  fi

  printf '%s%s%s' "$ansi_gray" "$divider" "$ansi_reset"
  printf '%sProject / tmux session:%s %s%s\n' \
    "$ansi_cyan" \
    "$ansi_reset" \
    "$project_name" \
    "$current_suffix"
  printf '%s%s%s' \
    "$ansi_dim" \
    "$summary_line" \
    "$ansi_reset"
  printf '%s%s%s' "$ansi_gray" "$(repeat_char '-' "$cols")" "$ansi_reset"
}

render_row() {
  local index="$1"
  local row="$2"
  local cols label_width line_prefix target state kind pane_label state_chip line
  local pane_id session_name pane_current_path

  IFS="$separator" read -r pane_id kind state session_name window_index pane_index pane_label pane_current_path <<< "$row"

  cols="$(screen_width)"
  label_width=$((cols - 32))
  if [ "$label_width" -lt 12 ]; then
    label_width=12
  fi

  target="${window_index}.${pane_index}"
  state_chip="$(state_badge "$state")"
  line_prefix="$(printf '%2s' "$((index + 1))")"

  line="$(printf '%s  %s %-7s %-5s %s' \
    "$line_prefix" \
    "$state_chip" \
    "$(printf '%s' "$kind" | tr '[:upper:]' '[:lower:]')" \
    "$target" \
    "$(truncate_text "$pane_label" "$label_width")")"

  if [ "$index" -eq "$selected_index" ]; then
    printf '%s> %s%s\n' "$ansi_bold" "$line" "$ansi_reset"
    return
  fi

  printf '  %s\n' "$line"
}

render_selected_details() {
  local cols label_width
  local pane_id kind state session_name window_index pane_index pane_label pane_current_path

  if [ "${#rows[@]}" -eq 0 ]; then
    return
  fi

  cols="$(screen_width)"
  label_width=$((cols - 16))
  if [ "$label_width" -lt 20 ]; then
    label_width=20
  fi

  IFS="$separator" read -r pane_id kind state session_name window_index pane_index pane_label pane_current_path <<< "${rows[$selected_index]}"

  printf '\n%sSelected:%s %s:%s.%s  %s  [%s]\n' \
    "$ansi_bold" \
    "$ansi_reset" \
    "$session_name" \
    "$window_index" \
    "$pane_index" \
    "$(state_badge "$state")" \
    "$(printf '%s' "$kind" | tr '[:upper:]' '[:lower:]')"

  printf '%sPath:%s %s\n' \
    "$ansi_dim" \
    "$ansi_reset" \
    "$(truncate_text "$pane_current_path" "$label_width")"
}

build_screen() {
  local previous_project=""
  local i

  printf '%sAgent Sessions%s\n' "$ansi_bold" "$ansi_reset"
  printf '%s%s%s\n' "$ansi_dim" "$(global_summary_line)" "$ansi_reset"
  printf '%sEach project below is one tmux session%s\n' "$ansi_dim" "$ansi_reset"
  printf '%sEnter jump | j/k move | [/] project | r refresh | q close%s\n' "$ansi_dim" "$ansi_reset"
  printf '\n'

  if [ "${#rows[@]}" -eq 0 ]; then
    printf 'No Codex or Claude panes found.\n'
    return
  fi

  for i in "${!rows[@]}"; do
    local pane_id kind state session_name window_index pane_index pane_label pane_current_path

    IFS="$separator" read -r pane_id kind state session_name window_index pane_index pane_label pane_current_path <<< "${rows[$i]}"

    if [ "$session_name" != "$previous_project" ]; then
      if [ -n "$previous_project" ]; then
        printf '\n'
      fi
      render_project_header "$session_name"
      previous_project="$session_name"
    fi

    render_row "$i" "${rows[$i]}"
  done

  render_selected_details
}

render_screen() {
  local screen

  screen="$(build_screen)"

  if [ "$screen" = "$last_screen" ]; then
    return
  fi

  last_screen="$screen"
  printf '\033[H\033[2J%s\n' "$screen"
}

move_selection() {
  local direction="$1"
  local current_project candidate_project i

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
    next_project)
      IFS="$separator" read -r _ _ _ current_project _ <<< "${rows[$selected_index]}"
      for ((i = selected_index + 1; i < ${#rows[@]}; i++)); do
        IFS="$separator" read -r _ _ _ candidate_project _ <<< "${rows[$i]}"
        if [ "$candidate_project" != "$current_project" ]; then
          selected_index="$i"
          return
        fi
      done
      ;;
    previous_project)
      IFS="$separator" read -r _ _ _ current_project _ <<< "${rows[$selected_index]}"
      for ((i = selected_index - 1; i >= 0; i--)); do
        IFS="$separator" read -r _ _ _ candidate_project _ <<< "${rows[$i]}"
        if [ "$candidate_project" != "$current_project" ]; then
          while [ "$i" -gt 0 ]; do
            local previous_project
            IFS="$separator" read -r _ _ _ previous_project _ <<< "${rows[$((i - 1))]}"
            if [ "$previous_project" = "$candidate_project" ]; then
              i=$((i - 1))
            else
              break
            fi
          done
          selected_index="$i"
          return
        fi
      done
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
    '[') move_selection previous_project ;;
    ']') move_selection next_project ;;
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
    $'\t')
      move_selection next_project
      ;;
    $'\e')
      if read -rsn2 -t 0.05 extra; then
        case "$extra" in
          '[A') move_selection up ;;
          '[B') move_selection down ;;
          '[Z') move_selection previous_project ;;
        esac
      else
        exit 0
      fi
      ;;
  esac
}

cleanup() {
  printf '\033[0m\033[?25h'
}

main() {
  trap cleanup EXIT
  printf '\033[?25l'

  collect_rows
  render_screen

  while true; do
    local key=''
    if read -rsn1 -t 1 key; then
      handle_key "$key"
      render_screen
    else
      collect_rows
      render_screen
    fi
  done
}

main
