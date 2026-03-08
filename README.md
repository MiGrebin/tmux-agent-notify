# tmux-agent-notify

Tmux plugin for Codex and Claude Code workflows.

It watches tmux panes, identifies Codex or Claude sessions from the pane
process tree, and then:

- sends a macOS notification when a session needs input
- sends a macOS notification when a session is idle and waiting for you
- adds an `AI` segment to `status-right` with attention and done counts
- binds `prefix + A` to jump to the next pane that needs attention
- binds `prefix + a` to open a floating popup grouped by tmux session

## Install with TPM

Add this to your `~/.tmux.conf`:

```tmux
set -g @plugin 'MiGrebin/tmux-agent-notify'
```

Then reload tmux and install plugins with TPM.

## Local development install

```tmux
run-shell '~/Projects/tmux-agent-notify/agent-notify.tmux'
```

## Defaults

```tmux
set -g @agent_notify_key 'A'
set -g @agent_notify_popup_key 'a'
set -g @agent_notify_dashboard_mode 'popup'
set -g @agent_notify_interval '5'
set -g @agent_notify_capture_lines '80'
```

## Popup dashboard

By default, `prefix + a` opens a floating popup. It only shows Codex and Claude panes, grouped by tmux `session_name`, which the plugin treats as the project name.

- `Up` / `Down` move
- `j` / `k` move
- `Enter` jumps
- `[` / `]` jump between projects
- `Tab` jumps to the next project
- `q` closes

The popup keeps the floating-pane workflow but uses the monitor metadata for grouping and pane state, so it no longer needs a custom process scan on every redraw.

## Native dashboard mode

If you want the tmux-native chooser instead:

```tmux
set -g @agent_notify_dashboard_mode 'native'
```

In `popup` mode, the sizing options apply:

```tmux
set -g @agent_notify_popup_width '80%'
set -g @agent_notify_popup_height '70%'
set -g @agent_notify_popup_title 'Agent Sessions'
```

## Useful overrides

Tune the process detection:

```tmux
set -g @agent_notify_process_pattern '(/bin/codex|/@openai/codex|(^|[[:space:]/])claude([[:space:]]|$)|/@anthropic-ai/claude-code)'
```

Tune the attention detector:

```tmux
set -g @agent_notify_attention_patterns 'Would you like to run the following command\?|Press enter to confirm|Yes, proceed|continue\?|approve|permission required|requires approval'
```

Tune the done detector:

```tmux
set -g @agent_notify_done_prompt_patterns '^[[:space:]]*[›>][[:space:]]'
```

## Behavior

- On macOS, notifications are sent through `osascript`.
- On other systems, the plugin falls back to `tmux display-message`.
- Attention detection is heuristic-based and only looks at the bottom of the
  visible pane, so old scrollback does not keep retriggering alerts.
- The popup and native dashboard both rely on tmux-local metadata written by
  the monitor for session, window, and pane summaries.
- Codex is detected from `node .../bin/codex` child processes.
- Claude is detected from `claude` or `@anthropic-ai/claude-code` child
  processes.
