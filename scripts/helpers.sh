#!/usr/bin/env bash

get_tmux_option() {
  local option="$1"
  local default_value="${2:-}"
  local option_value

  option_value="$(tmux show-option -gqv "$option" 2>/dev/null || true)"

  if [ -n "$option_value" ]; then
    printf '%s\n' "$option_value"
  else
    printf '%s\n' "$default_value"
  fi
}

set_tmux_option() {
  local option="$1"
  local value="${2:-}"
  tmux set-option -gq "$option" "$value"
}

set_tmux_target_option() {
  local scope="$1"
  local target="$2"
  local option="$3"
  local value="${4:-}"

  case "$scope" in
    pane)
      tmux set-option -pq -t "$target" "$option" "$value"
      ;;
    window)
      tmux set-option -wq -t "$target" "$option" "$value"
      ;;
    session)
      tmux set-option -q -t "$target" "$option" "$value"
      ;;
    *)
      return 1
      ;;
  esac
}

unset_tmux_option() {
  local option="$1"
  tmux set-option -gu "$option" >/dev/null 2>&1 || true
}

unset_tmux_target_option() {
  local scope="$1"
  local target="$2"
  local option="$3"

  case "$scope" in
    pane)
      tmux set-option -pu -t "$target" "$option" >/dev/null 2>&1 || true
      ;;
    window)
      tmux set-option -wu -t "$target" "$option" >/dev/null 2>&1 || true
      ;;
    session)
      tmux set-option -u -t "$target" "$option" >/dev/null 2>&1 || true
      ;;
    *)
      return 1
      ;;
  esac
}

pane_key() {
  printf '%s\n' "${1#%}" | tr -cd '0-9'
}

has_list_item() {
  local list="$1"
  local needle="$2"
  local item

  for item in $list; do
    if [ "$item" = "$needle" ]; then
      return 0
    fi
  done

  return 1
}

trim_whitespace() {
  printf '%s\n' "$1" | awk '{$1=$1; print}'
}

agent_kind_for_pane() {
  local pane_pid="$1"
  local pane_title="$2"
  local process_pattern="$3"
  local command_line=""

  command_line="$(ps -axo ppid=,command= 2>/dev/null | awk -v pane_pid="$pane_pid" -v pattern="$process_pattern" '
    BEGIN { IGNORECASE = 1 }
    $1 == pane_pid {
      command = substr($0, index($0, $2))
      if (command ~ pattern) {
        print command
        exit
      }
    }
  ')" || true

  if [ -n "$command_line" ]; then
    if printf '%s\n' "$command_line" | grep -Eiq 'claude'; then
      printf 'claude\n'
    else
      printf 'codex\n'
    fi
    return 0
  fi

  if printf '%s\n' "$pane_title" | grep -Eiq 'claude'; then
    printf 'claude\n'
    return 0
  fi

  if printf '%s\n' "$pane_title" | grep -Eiq 'codex'; then
    printf 'codex\n'
    return 0
  fi

  return 1
}

pane_target() {
  tmux display-message -p -t "$1" '#{session_name}:#{window_index}' 2>/dev/null || true
}

switch_to_pane() {
  local pane_id="$1"
  local target

  target="$(pane_target "$pane_id")"

  if [ -z "$target" ]; then
    return 1
  fi

  tmux switch-client -t "${target%%:*}"
  tmux select-window -t "$target"
  tmux select-pane -t "$pane_id"
}
