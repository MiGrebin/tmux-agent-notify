package config

import (
	"os"
	"path/filepath"
	"strings"
)

const (
	KeyOption                = "@agent_notify_key"
	PopupKeyOption           = "@agent_notify_popup_key"
	DashboardModeOption      = "@agent_notify_dashboard_mode"
	IntervalOption           = "@agent_notify_interval"
	CaptureLinesOption       = "@agent_notify_capture_lines"
	PopupWidthOption         = "@agent_notify_popup_width"
	PopupHeightOption        = "@agent_notify_popup_height"
	PopupTitleOption         = "@agent_notify_popup_title"
	ProcessPatternOption     = "@agent_notify_process_pattern"
	AttentionPatternsOption  = "@agent_notify_attention_patterns"
	DonePromptPatternsOption = "@agent_notify_done_prompt_patterns"
	StatusOption             = "@agent_notify_status"
	AttentionPanesOption     = "@agent_notify_attention_panes"
	DonePanesOption          = "@agent_notify_done_panes"
	AllPanesOption           = "@agent_notify_all_panes"
	LastTargetOption         = "@agent_notify_last_target"
	MonitorPIDOption         = "@agent_notify_monitor_pid"

	PaneAgentOption        = "@agent_notify_is_agent"
	PaneKindLabelOption    = "@agent_notify_pane_kind_label"
	PaneStateOption        = "@agent_notify_pane_state"
	PaneStateBadgeOption   = "@agent_notify_pane_state_badge"
	PaneLabelOption        = "@agent_notify_pane_label"
	WindowHasAgentsOption  = "@agent_notify_window_has_agents"
	WindowSummaryOption    = "@agent_notify_window_summary"
	SessionHasAgentsOption = "@agent_notify_session_has_agents"
	SessionSummaryOption   = "@agent_notify_session_summary"
)

var DefaultOptions = map[string]string{
	KeyOption:                "A",
	PopupKeyOption:           "a",
	DashboardModeOption:      "popup",
	IntervalOption:           "5",
	CaptureLinesOption:       "80",
	PopupWidthOption:         "80%",
	PopupHeightOption:        "70%",
	PopupTitleOption:         "Agent Sessions",
	ProcessPatternOption:     `(/bin/codex|/@openai/codex|(^|[[:space:]/])claude([[:space:]]|$)|/@anthropic-ai/claude-code)`,
	AttentionPatternsOption:  `Would you like to run the following command\?|Press enter to confirm|Yes, proceed|don.t ask again|needs input|waiting for input|select an option|choose an option|continue\?|approve|approval|permission required|requires approval|allow.*command`,
	DonePromptPatternsOption: `^[[:space:]]*[›>][[:space:]]`,
}

func SignatureOption(key string) string {
	return "@agent_notify_signature_" + key
}

func StateSnapshotOption(key string) string {
	return "@agent_notify_state_" + key
}

func PluginRoot() string {
	if root := os.Getenv("TMUX_AGENT_NOTIFY_ROOT"); root != "" {
		return root
	}

	exe, err := os.Executable()
	if err == nil {
		return filepath.Clean(filepath.Join(filepath.Dir(exe), ".."))
	}

	wd, err := os.Getwd()
	if err == nil {
		return wd
	}

	return "."
}

func ShellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", `'"'"'`) + "'"
}
