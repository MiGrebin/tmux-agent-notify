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

unset_tmux_option() {
  local option="$1"
  tmux set-option -gu "$option" >/dev/null 2>&1 || true
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
