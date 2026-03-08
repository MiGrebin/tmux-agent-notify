package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"

	"github.com/MiGrebin/tmux-agent-notify/internal/config"
	"github.com/MiGrebin/tmux-agent-notify/internal/monitor"
	"github.com/MiGrebin/tmux-agent-notify/internal/notify"
	"github.com/MiGrebin/tmux-agent-notify/internal/tmuxcli"
	"github.com/MiGrebin/tmux-agent-notify/internal/ui"
)

func main() {
	root := config.PluginRoot()
	tmux := tmuxcli.New()
	notifier := notify.New(tmux)
	runner := monitor.NewRunner(root, tmux, notifier)

	var err error
	args := os.Args[1:]
	if len(args) == 0 {
		args = []string{"bootstrap"}
	}

	switch args[0] {
	case "bootstrap":
		err = bootstrap(tmux, root, runner)
	case "monitor":
		err = handleMonitor(runner, args[1:])
	case "next-pane":
		err = nextPane(tmux)
	case "open-dashboard":
		err = openDashboard(tmux, root)
	case "popup":
		err = ui.NewPopup(tmux).Run()
	default:
		err = fmt.Errorf("unknown command %q", args[0])
	}

	if err != nil {
		_ = tmux.DisplayMessage(err.Error())
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func bootstrap(tmux *tmuxcli.Client, root string, runner *monitor.Runner) error {
	for option, value := range config.DefaultOptions {
		if tmux.Option(option, "") == "" {
			if err := tmux.SetOption(option, value); err != nil {
				return err
			}
		}
	}

	if err := ensureStatusSegment(tmux); err != nil {
		return err
	}

	nextPaneCommand := config.ShellQuote(filepath.Join(root, "scripts", "next-pane.sh"))
	openDashboardCommand := config.ShellQuote(filepath.Join(root, "scripts", "open-popup.sh"))

	keyBinding := tmux.Option(config.KeyOption, config.DefaultOptions[config.KeyOption])
	if err := tmux.BindKey(keyBinding, nextPaneCommand); err != nil {
		return err
	}

	popupKeyBinding := tmux.Option(config.PopupKeyOption, config.DefaultOptions[config.PopupKeyOption])
	if err := tmux.BindKey(popupKeyBinding, openDashboardCommand); err != nil {
		return err
	}

	return runner.Start()
}

func handleMonitor(runner *monitor.Runner, args []string) error {
	mode := "run"
	if len(args) > 0 {
		mode = args[0]
	}

	switch mode {
	case "start":
		return runner.Start()
	case "stop":
		return runner.Stop()
	case "run":
		ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
		defer stop()
		return runner.Run(ctx)
	default:
		return fmt.Errorf("usage: agent-notify monitor [start|stop|run]")
	}
}

func ensureStatusSegment(tmux *tmuxcli.Client) error {
	statusRight := tmux.Option("status-right", "")
	if strings.Contains(statusRight, "#{@agent_notify_status}") {
		return nil
	}

	if statusRight != "" {
		return tmux.SetOption("status-right", statusRight+" #{@agent_notify_status}")
	}

	return tmux.SetOption("status-right", "#{@agent_notify_status}")
}

func nextPane(tmux *tmuxcli.Client) error {
	attentionPanes := strings.Fields(tmux.Option(config.AttentionPanesOption, ""))
	donePanes := strings.Fields(tmux.Option(config.DonePanesOption, ""))

	panes := attentionPanes
	if len(panes) == 0 {
		panes = donePanes
	}

	if len(panes) == 0 {
		return tmux.DisplayMessage("No Codex or Claude panes are waiting")
	}

	lastTarget := tmux.Option(config.LastTargetOption, "")
	nextPaneID := pickNextPane(panes, lastTarget)
	if nextPaneID == "" {
		return tmux.DisplayMessage("No Codex or Claude panes are waiting")
	}

	if err := tmux.SwitchToPane(nextPaneID); err != nil {
		return tmux.DisplayMessage(fmt.Sprintf("Pane %s is no longer available", nextPaneID))
	}

	return tmux.SetOption(config.LastTargetOption, nextPaneID)
}

func pickNextPane(panes []string, lastTarget string) string {
	if len(panes) == 0 {
		return ""
	}

	if lastTarget != "" {
		for index, pane := range panes {
			if pane == lastTarget && index+1 < len(panes) {
				return panes[index+1]
			}
		}
	}

	return panes[0]
}

func openDashboard(tmux *tmuxcli.Client, root string) error {
	dashboardMode := tmux.Option(config.DashboardModeOption, config.DefaultOptions[config.DashboardModeOption])
	if dashboardMode == "popup" {
		width := tmux.Option(config.PopupWidthOption, config.DefaultOptions[config.PopupWidthOption])
		height := tmux.Option(config.PopupHeightOption, config.DefaultOptions[config.PopupHeightOption])
		title := tmux.Option(config.PopupTitleOption, config.DefaultOptions[config.PopupTitleOption])
		command := config.ShellQuote(filepath.Join(root, "scripts", "popup.sh"))
		return tmux.DisplayPopup(width, height, title, command)
	}

	allPanes := tmux.Option(config.AllPanesOption, "")
	if allPanes == "" {
		return tmux.DisplayMessage("No Codex or Claude panes found")
	}

	targetPane, err := tmux.CurrentPaneID()
	if err != nil || targetPane == "" {
		return fmt.Errorf("no active tmux pane found")
	}

	filter := "#{?pane_format,#{==:#{@agent_notify_is_agent},1},#{?window_format,#{==:#{@agent_notify_window_has_agents},1},#{==:#{@agent_notify_session_has_agents},1}}}"
	format := "#{?pane_format,#{@agent_notify_pane_state_badge} #[fg=colour81]#{@agent_notify_pane_kind_label}#[default] #[fg=colour250]#{window_index}.#{pane_index}#[default] #{@agent_notify_pane_label},#{?window_format,#[fg=colour250]#{window_index}#[default] #{window_name}#{?#{!=:#{@agent_notify_window_summary},},  #{@agent_notify_window_summary},},#[bold]#{session_name}#[default]#{?#{==:#{session_name},#{client_session}}, #[fg=colour39 bold][current]#[default],}#{?#{!=:#{@agent_notify_session_summary},},  #{@agent_notify_session_summary},}}}"
	template := "switch-client -t '%%' \\; select-window -t '%%' \\; select-pane -t '%%'"
	return tmux.ChooseTree(targetPane, filter, format, template)
}
