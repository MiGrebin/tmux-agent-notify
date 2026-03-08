package monitor

import (
	"context"
	"errors"
	"fmt"
	"hash/crc32"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/MiGrebin/tmux-agent-notify/internal/agent"
	"github.com/MiGrebin/tmux-agent-notify/internal/config"
	"github.com/MiGrebin/tmux-agent-notify/internal/notify"
	"github.com/MiGrebin/tmux-agent-notify/internal/tmuxcli"
)

type Runner struct {
	tmux      *tmuxcli.Client
	notifier  *notify.Notifier
	serverKey string
}

type settings struct {
	Interval     time.Duration
	CaptureLines int
	Detector     agent.Detector
	Classifier   Classifier
}

type agentRow struct {
	PaneID       string
	Kind         string
	State        State
	DisplayState State
	SessionName  string
	WindowIndex  int
	PaneIndex    int
	PaneTitle    string
	PanePath     string
	WindowName   string
}

type aggregateKey struct {
	scope  string
	target string
}

type aggregateCounts struct {
	attention int
	done      int
	busy      int
	current   int
	total     int
}

func NewRunner(root string, tmux *tmuxcli.Client, notifier *notify.Notifier) *Runner {
	return &Runner{
		tmux:      tmux,
		notifier:  notifier,
		serverKey: monitorServerKey(tmux, root),
	}
}

func (r *Runner) Start() error {
	if pid := r.existingMonitorPID(); pid > 0 {
		return nil
	}

	exe, err := os.Executable()
	if err != nil {
		return err
	}

	devNull, err := os.OpenFile(os.DevNull, os.O_RDWR, 0o644)
	if err != nil {
		return err
	}
	defer devNull.Close()

	cmd := exec.Command(exe, "monitor", "run")
	cmd.Env = os.Environ()
	cmd.Stdin = devNull
	cmd.Stdout = devNull
	cmd.Stderr = devNull
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	return cmd.Start()
}

func (r *Runner) Stop() error {
	existingPID := r.existingMonitorPID()
	if existingPID > 0 {
		_ = syscall.Kill(existingPID, syscall.SIGTERM)
	}

	_ = os.Remove(r.pidFile())
	_ = os.Remove(r.lockDir())
	r.resetState()
	return nil
}

func (r *Runner) Run(ctx context.Context) error {
	locked, err := r.acquireRunLock()
	if err != nil || !locked {
		return err
	}
	defer r.releaseRunLock()

	firstPass := true
	for {
		if err := ctx.Err(); err != nil {
			return nil
		}

		settings := r.loadSettings()
		if err := r.runIteration(settings, firstPass); err != nil {
			return err
		}

		firstPass = false

		select {
		case <-ctx.Done():
			return nil
		case <-time.After(settings.Interval):
		}
	}
}

func (r *Runner) runIteration(settings settings, firstPass bool) error {
	panes, err := r.tmux.ListPanesAll()
	if err != nil {
		return nil
	}

	snapshot, _ := agent.ScanSnapshot()

	attentionPanes := make([]string, 0)
	donePanes := make([]string, 0)
	allPanes := make([]string, 0)
	agentRows := make([]agentRow, 0)

	attentionCount := 0
	doneCount := 0

	for _, pane := range panes {
		kind, ok := settings.Detector.KindForPane(snapshot, pane.PID, pane.Title)
		if !ok {
			continue
		}

		paneText, _ := r.tmux.CapturePane(pane.ID, settings.CaptureLines)
		state := settings.Classifier.Classify(paneText)
		displayState := DisplayStateForPane(state, pane.PaneActive, pane.WindowActive, pane.SessionAttached)
		key := PaneKey(pane.ID)
		signature := fmt.Sprintf("%s|%s", state, CaptureSignature(paneText))
		previousSignature := r.tmux.Option(config.SignatureOption(key), "")

		_ = r.tmux.SetOption(config.SignatureOption(key), signature)
		_ = r.tmux.SetOption(config.StateSnapshotOption(key), string(state))

		allPanes = append(allPanes, pane.ID)
		agentRows = append(agentRows, agentRow{
			PaneID:       pane.ID,
			Kind:         string(kind),
			State:        state,
			DisplayState: displayState,
			SessionName:  pane.SessionName,
			WindowIndex:  pane.WindowIndex,
			PaneIndex:    pane.PaneIndex,
			PaneTitle:    pane.Title,
			PanePath:     pane.CurrentPath,
			WindowName:   pane.WindowName,
		})

		if ShouldNotifyForPane(pane.PaneActive, pane.WindowActive, pane.SessionAttached) {
			switch state {
			case StateAttention:
				attentionPanes = append(attentionPanes, pane.ID)
				attentionCount++
			case StateDone:
				donePanes = append(donePanes, pane.ID)
				doneCount++
			}
		}

		if firstPass || signature == previousSignature || !ShouldNotifyForPane(pane.PaneActive, pane.WindowActive, pane.SessionAttached) {
			continue
		}

		if state == StateAttention || state == StateDone {
			label := PaneLabel(pane.SessionName, pane.WindowIndex, pane.PaneIndex, pane.Title)
			r.notifier.Notify(string(kind), string(state), label)
		}
	}

	r.applyTreeMetadata(agentRows)

	previousStatus := r.tmux.Option(config.StatusOption, "")
	newStatus := StatusText(attentionCount, doneCount)

	_ = r.tmux.SetOption(config.AttentionPanesOption, strings.Join(attentionPanes, " "))
	_ = r.tmux.SetOption(config.DonePanesOption, strings.Join(donePanes, " "))
	_ = r.tmux.SetOption(config.AllPanesOption, strings.Join(allPanes, " "))
	_ = r.tmux.SetOption(config.StatusOption, newStatus)

	if newStatus != previousStatus {
		_ = r.tmux.RefreshClient()
	}

	return nil
}

func (r *Runner) applyTreeMetadata(rows []agentRow) {
	if len(rows) == 0 {
		r.clearTreeMetadata()
		return
	}

	aggregates := map[aggregateKey]*aggregateCounts{}
	currentPaneIDs := make(map[string]struct{}, len(rows))
	currentWindowTargets := make(map[string]struct{})
	currentSessionNames := make(map[string]struct{})

	for _, row := range rows {
		currentPaneIDs[row.PaneID] = struct{}{}
		windowTarget := fmt.Sprintf("%s:%d", row.SessionName, row.WindowIndex)
		currentWindowTargets[windowTarget] = struct{}{}
		currentSessionNames[row.SessionName] = struct{}{}

		_ = r.tmux.SetTargetOption("pane", row.PaneID, config.PaneAgentOption, "1")
		_ = r.tmux.SetTargetOption("pane", row.PaneID, config.PaneKindLabelOption, KindLabel(row.Kind))
		_ = r.tmux.SetTargetOption("pane", row.PaneID, config.PaneStateOption, string(row.DisplayState))
		_ = r.tmux.SetTargetOption("pane", row.PaneID, config.PaneStateBadgeOption, PaneStateBadge(row.DisplayState))
		_ = r.tmux.SetTargetOption("pane", row.PaneID, config.PaneLabelOption, PaneItemLabel(row.WindowName, row.PaneTitle, row.PanePath))

		r.bumpAggregate(aggregates, aggregateKey{scope: "session", target: row.SessionName}, row.DisplayState)
		r.bumpAggregate(aggregates, aggregateKey{scope: "window", target: windowTarget}, row.DisplayState)
	}

	for key, counts := range aggregates {
		summary := SummaryBadge(counts.attention, counts.done, counts.busy, counts.current, counts.total)
		switch key.scope {
		case "session":
			_ = r.tmux.SetTargetOption("session", key.target, config.SessionHasAgentsOption, "1")
			_ = r.tmux.SetTargetOption("session", key.target, config.SessionSummaryOption, summary)
		case "window":
			_ = r.tmux.SetTargetOption("window", key.target, config.WindowHasAgentsOption, "1")
			_ = r.tmux.SetTargetOption("window", key.target, config.WindowSummaryOption, summary)
		}
	}

	r.clearStaleTreeMetadata(currentPaneIDs, currentWindowTargets, currentSessionNames)
}

func (r *Runner) bumpAggregate(aggregates map[aggregateKey]*aggregateCounts, key aggregateKey, state State) {
	counts, ok := aggregates[key]
	if !ok {
		counts = &aggregateCounts{}
		aggregates[key] = counts
	}

	counts.total++
	switch state {
	case StateAttention:
		counts.attention++
	case StateDone:
		counts.done++
	case StateBusy:
		counts.busy++
	case StateCurrent:
		counts.current++
	}
}

func (r *Runner) clearTreeMetadata() {
	paneIDs, _ := r.tmux.ListPaneIDs("#{==:#{@agent_notify_is_agent},1}")
	for _, paneID := range paneIDs {
		_ = r.tmux.SetTargetOption("pane", paneID, config.PaneAgentOption, "0")
	}

	windowTargets, _ := r.tmux.ListWindowTargets("#{==:#{@agent_notify_window_has_agents},1}")
	for _, target := range windowTargets {
		_ = r.tmux.SetTargetOption("window", target, config.WindowHasAgentsOption, "0")
	}

	sessionNames, _ := r.tmux.ListSessionNames("#{==:#{@agent_notify_session_has_agents},1}")
	for _, sessionName := range sessionNames {
		_ = r.tmux.SetTargetOption("session", sessionName, config.SessionHasAgentsOption, "0")
	}
}

func (r *Runner) clearStaleTreeMetadata(currentPaneIDs, currentWindowTargets, currentSessionNames map[string]struct{}) {
	paneIDs, _ := r.tmux.ListPaneIDs("#{==:#{@agent_notify_is_agent},1}")
	for _, paneID := range paneIDs {
		if _, ok := currentPaneIDs[paneID]; ok {
			continue
		}
		_ = r.tmux.SetTargetOption("pane", paneID, config.PaneAgentOption, "0")
	}

	windowTargets, _ := r.tmux.ListWindowTargets("#{==:#{@agent_notify_window_has_agents},1}")
	for _, target := range windowTargets {
		if _, ok := currentWindowTargets[target]; ok {
			continue
		}
		_ = r.tmux.SetTargetOption("window", target, config.WindowHasAgentsOption, "0")
	}

	sessionNames, _ := r.tmux.ListSessionNames("#{==:#{@agent_notify_session_has_agents},1}")
	for _, sessionName := range sessionNames {
		if _, ok := currentSessionNames[sessionName]; ok {
			continue
		}
		_ = r.tmux.SetTargetOption("session", sessionName, config.SessionHasAgentsOption, "0")
	}
}

func (r *Runner) loadSettings() settings {
	intervalSeconds := parseInt(r.tmux.Option(config.IntervalOption, config.DefaultOptions[config.IntervalOption]))
	if intervalSeconds <= 0 {
		intervalSeconds = 5
	}

	captureLines := parseInt(r.tmux.Option(config.CaptureLinesOption, config.DefaultOptions[config.CaptureLinesOption]))
	if captureLines <= 0 {
		captureLines = 80
	}

	processPattern := r.tmux.Option(config.ProcessPatternOption, config.DefaultOptions[config.ProcessPatternOption])
	attentionPattern := r.tmux.Option(config.AttentionPatternsOption, config.DefaultOptions[config.AttentionPatternsOption])
	donePattern := r.tmux.Option(config.DonePromptPatternsOption, config.DefaultOptions[config.DonePromptPatternsOption])

	return settings{
		Interval:     time.Duration(intervalSeconds) * time.Second,
		CaptureLines: captureLines,
		Detector:     agent.NewDetector(processPattern, config.DefaultOptions[config.ProcessPatternOption]),
		Classifier: NewClassifier(
			attentionPattern,
			config.DefaultOptions[config.AttentionPatternsOption],
			donePattern,
			config.DefaultOptions[config.DonePromptPatternsOption],
		),
	}
}

func (r *Runner) acquireRunLock() (bool, error) {
	existingPID := r.existingMonitorPID()
	if existingPID > 0 && existingPID != os.Getpid() {
		_ = r.tmux.SetOption(config.MonitorPIDOption, strconv.Itoa(existingPID))
		return false, nil
	}

	if err := os.Mkdir(r.lockDir(), 0o700); err == nil {
		return true, r.writeLockPID()
	} else if !errors.Is(err, os.ErrExist) {
		return false, err
	}

	existingPID = r.lockPID()
	if existingPID > 0 && processExists(existingPID) {
		_ = r.tmux.SetOption(config.MonitorPIDOption, strconv.Itoa(existingPID))
		return false, nil
	}

	_ = os.Remove(r.pidFile())
	_ = os.Remove(r.lockDir())

	if err := os.Mkdir(r.lockDir(), 0o700); err != nil {
		if errors.Is(err, os.ErrExist) {
			return false, nil
		}
		return false, err
	}

	return true, r.writeLockPID()
}

func (r *Runner) writeLockPID() error {
	pid := os.Getpid()
	if err := os.WriteFile(r.pidFile(), []byte(strconv.Itoa(pid)), 0o600); err != nil {
		return err
	}
	return r.tmux.SetOption(config.MonitorPIDOption, strconv.Itoa(pid))
}

func (r *Runner) releaseRunLock() {
	if r.lockPID() == os.Getpid() {
		_ = os.Remove(r.pidFile())
		_ = os.Remove(r.lockDir())
	}
	r.resetState()
}

func (r *Runner) resetState() {
	r.clearTreeMetadata()
	_ = r.tmux.UnsetOption(config.MonitorPIDOption)
	_ = r.tmux.SetOption(config.StatusOption, "")
	_ = r.tmux.SetOption(config.AttentionPanesOption, "")
	_ = r.tmux.SetOption(config.DonePanesOption, "")
	_ = r.tmux.SetOption(config.AllPanesOption, "")
}

func (r *Runner) lockDir() string {
	lockKey := crc32.ChecksumIEEE([]byte(r.serverKey))
	return filepath.Join(os.TempDir(), fmt.Sprintf("tmux-agent-notify-%d.lock", lockKey))
}

func (r *Runner) pidFile() string {
	return filepath.Join(r.lockDir(), "pid")
}

func (r *Runner) lockPID() int {
	data, err := os.ReadFile(r.pidFile())
	if err != nil {
		return 0
	}
	return parseInt(strings.TrimSpace(string(data)))
}

func processExists(pid int) bool {
	if pid <= 0 {
		return false
	}
	return syscall.Kill(pid, 0) == nil
}

func (r *Runner) existingMonitorPID() int {
	if pid := parseInt(r.tmux.Option(config.MonitorPIDOption, "0")); processExists(pid) {
		return pid
	}

	if pid := r.lockPID(); processExists(pid) {
		return pid
	}

	return 0
}

func monitorServerKey(tmux *tmuxcli.Client, fallback string) string {
	if socketPath := socketPathFromEnv(os.Getenv("TMUX")); socketPath != "" {
		return socketPath
	}

	if tmux != nil {
		if socketPath, err := tmux.SocketPath(); err == nil && strings.TrimSpace(socketPath) != "" {
			return strings.TrimSpace(socketPath)
		}
	}

	return fallback
}

func socketPathFromEnv(value string) string {
	if value == "" {
		return ""
	}

	socketPath, _, found := strings.Cut(value, ",")
	if !found {
		return strings.TrimSpace(value)
	}

	return strings.TrimSpace(socketPath)
}

func parseInt(value string) int {
	n, _ := strconv.Atoi(strings.TrimSpace(value))
	return n
}
