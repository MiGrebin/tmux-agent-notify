package ui

import (
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/MiGrebin/tmux-agent-notify/internal/monitor"
	"github.com/MiGrebin/tmux-agent-notify/internal/tmuxcli"
)

const (
	ansiReset  = "\033[0m"
	ansiBold   = "\033[1m"
	ansiDim    = "\033[2m"
	ansiYellow = "\033[33m"
	ansiGreen  = "\033[32m"
	ansiCyan   = "\033[36m"
	ansiGray   = "\033[90m"
)

type Popup struct {
	tmux          *tmuxcli.Client
	rows          []row
	selectedIndex int
	lastScreen    string
}

type row struct {
	PaneID      string
	Kind        string
	State       monitor.State
	SessionName string
	WindowIndex int
	PaneIndex   int
	Label       string
	CurrentPath string
}

type projectSummary struct {
	attentionCount   int
	doneCount        int
	busyCount        int
	currentCount     int
	paneCount        int
	isCurrentProject bool
}

type terminalState struct {
	original string
	tty      *os.File
	closeTTY bool
}

func NewPopup(tmux *tmuxcli.Client) *Popup {
	return &Popup{tmux: tmux}
}

func (p *Popup) Run() error {
	input, state, err := enterRawMode()
	if err != nil {
		return err
	}
	defer state.restore()

	fmt.Print("\033[?25l")
	defer fmt.Print("\033[0m\033[?25h")

	if err := p.collectRows(); err != nil {
		return err
	}
	p.renderScreen()

	buffer := make([]byte, 16)
	lastRefresh := time.Now()

	for {
		if time.Since(lastRefresh) >= time.Second {
			if err := p.collectRows(); err != nil {
				return err
			}
			p.renderScreen()
			lastRefresh = time.Now()
		}

		n, err := input.Read(buffer)
		if err != nil {
			if errors.Is(err, io.EOF) {
				continue
			}
			return err
		}
		if n == 0 {
			continue
		}

		shouldExit, err := p.handleBytes(buffer[:n])
		if err != nil {
			return err
		}
		if shouldExit {
			return nil
		}

		p.renderScreen()
	}
}

func (p *Popup) collectRows() error {
	previousPaneID := ""
	if len(p.rows) > 0 && p.selectedIndex >= 0 && p.selectedIndex < len(p.rows) {
		previousPaneID = p.rows[p.selectedIndex].PaneID
	}

	agentPanes, err := p.tmux.ListAgentPanes()
	if err != nil {
		return err
	}

	rows := make([]row, 0, len(agentPanes))
	for _, pane := range agentPanes {
		rows = append(rows, row{
			PaneID:      pane.ID,
			Kind:        pane.KindLabel,
			State:       monitor.State(pane.State),
			SessionName: pane.SessionName,
			WindowIndex: pane.WindowIndex,
			PaneIndex:   pane.PaneIndex,
			Label:       pane.Label,
			CurrentPath: pane.CurrentPath,
		})
	}

	currentSession, _ := p.tmux.CurrentSessionName()
	sort.Slice(rows, func(i, j int) bool {
		left := rows[i]
		right := rows[j]

		leftCurrent := left.SessionName == currentSession
		rightCurrent := right.SessionName == currentSession
		if leftCurrent != rightCurrent {
			return leftCurrent
		}

		leftSession := strings.ToLower(left.SessionName)
		rightSession := strings.ToLower(right.SessionName)
		if leftSession != rightSession {
			return leftSession < rightSession
		}

		leftRank := monitor.StateRank(left.State)
		rightRank := monitor.StateRank(right.State)
		if leftRank != rightRank {
			return leftRank < rightRank
		}

		if left.WindowIndex != right.WindowIndex {
			return left.WindowIndex < right.WindowIndex
		}

		return left.PaneIndex < right.PaneIndex
	})

	p.rows = rows
	if len(p.rows) == 0 {
		p.selectedIndex = 0
		return nil
	}

	if previousPaneID != "" {
		for index, pane := range p.rows {
			if pane.PaneID == previousPaneID {
				p.selectedIndex = index
				return nil
			}
		}
	}

	if p.selectedIndex >= len(p.rows) {
		p.selectedIndex = len(p.rows) - 1
	}
	if p.selectedIndex < 0 {
		p.selectedIndex = 0
	}

	return nil
}

func (p *Popup) handleBytes(data []byte) (bool, error) {
	for index := 0; index < len(data); index++ {
		switch data[index] {
		case 'q':
			return true, nil
		case 'r':
			if err := p.collectRows(); err != nil {
				return false, err
			}
		case 'j':
			p.moveSelection("down")
		case 'k':
			p.moveSelection("up")
		case '[':
			p.moveSelection("previous_project")
		case ']':
			p.moveSelection("next_project")
		case 'g':
			p.moveSelection("first")
		case 'G':
			p.moveSelection("last")
		case '\t':
			p.moveSelection("next_project")
		case '\r', '\n':
			return p.jumpToSelected()
		case 0x1b:
			if index+2 < len(data) && data[index+1] == '[' {
				switch data[index+2] {
				case 'A':
					p.moveSelection("up")
					index += 2
					continue
				case 'B':
					p.moveSelection("down")
					index += 2
					continue
				case 'Z':
					p.moveSelection("previous_project")
					index += 2
					continue
				}
			}
			return true, nil
		default:
			if data[index] >= '1' && data[index] <= '9' {
				target := int(data[index] - '1')
				if target < len(p.rows) {
					p.selectedIndex = target
					return p.jumpToSelected()
				}
			}
		}
	}

	return false, nil
}

func (p *Popup) moveSelection(direction string) {
	if len(p.rows) == 0 {
		return
	}

	switch direction {
	case "down":
		if p.selectedIndex < len(p.rows)-1 {
			p.selectedIndex++
		}
	case "up":
		if p.selectedIndex > 0 {
			p.selectedIndex--
		}
	case "next_project":
		currentProject := p.rows[p.selectedIndex].SessionName
		for index := p.selectedIndex + 1; index < len(p.rows); index++ {
			if p.rows[index].SessionName != currentProject {
				p.selectedIndex = index
				return
			}
		}
	case "previous_project":
		currentProject := p.rows[p.selectedIndex].SessionName
		for index := p.selectedIndex - 1; index >= 0; index-- {
			if p.rows[index].SessionName != currentProject {
				candidateProject := p.rows[index].SessionName
				for index > 0 && p.rows[index-1].SessionName == candidateProject {
					index--
				}
				p.selectedIndex = index
				return
			}
		}
	case "first":
		p.selectedIndex = 0
	case "last":
		p.selectedIndex = len(p.rows) - 1
	}
}

func (p *Popup) jumpToSelected() (bool, error) {
	if len(p.rows) == 0 {
		return false, nil
	}

	if err := p.tmux.SwitchToPane(p.rows[p.selectedIndex].PaneID); err == nil {
		return true, nil
	}

	return false, p.collectRows()
}

func (p *Popup) renderScreen() {
	screen := p.buildScreen()
	if screen == p.lastScreen {
		return
	}

	p.lastScreen = screen
	fmt.Printf("\033[H\033[2J%s\n", screen)
}

func (p *Popup) buildScreen() string {
	var builder strings.Builder

	builder.WriteString(ansiBold)
	builder.WriteString("Agent Sessions")
	builder.WriteString(ansiReset)
	builder.WriteString("\n")

	builder.WriteString(ansiDim)
	builder.WriteString(p.globalSummaryLine())
	builder.WriteString(ansiReset)
	builder.WriteString("\n")

	builder.WriteString(ansiDim)
	builder.WriteString("Each project below is one tmux session")
	builder.WriteString(ansiReset)
	builder.WriteString("\n")

	builder.WriteString(ansiDim)
	builder.WriteString("Enter jump | j/k move | [/] project | r refresh | q close")
	builder.WriteString(ansiReset)
	builder.WriteString("\n\n")

	if len(p.rows) == 0 {
		builder.WriteString("No Codex or Claude panes found.\n")
		return builder.String()
	}

	previousProject := ""
	currentSession, _ := p.tmux.CurrentSessionName()

	for index, currentRow := range p.rows {
		if currentRow.SessionName != previousProject {
			if previousProject != "" {
				builder.WriteString("\n")
			}
			builder.WriteString(p.renderProjectHeader(currentRow.SessionName, currentSession))
			previousProject = currentRow.SessionName
		}
		builder.WriteString(p.renderRow(index, currentRow))
	}

	builder.WriteString(p.renderSelectedDetails())
	return builder.String()
}

func (p *Popup) renderProjectHeader(projectName, currentSession string) string {
	summary := p.projectSummary(projectName, currentSession)
	var builder strings.Builder

	builder.WriteString(ansiGray)
	builder.WriteString(strings.Repeat("=", p.screenWidth()))
	builder.WriteString(ansiReset)
	builder.WriteString("\n")

	builder.WriteString(ansiCyan)
	builder.WriteString("Project / tmux session:")
	builder.WriteString(ansiReset)
	builder.WriteString(" ")
	builder.WriteString(projectName)
	if summary.isCurrentProject {
		builder.WriteString(" [current]")
	}
	builder.WriteString("\n")

	builder.WriteString(ansiDim)
	builder.WriteString(p.projectSummaryText(summary))
	builder.WriteString(ansiReset)
	builder.WriteString("\n")

	builder.WriteString(ansiGray)
	builder.WriteString(strings.Repeat("-", p.screenWidth()))
	builder.WriteString(ansiReset)
	builder.WriteString("\n")

	return builder.String()
}

func (p *Popup) renderRow(index int, currentRow row) string {
	cols := p.screenWidth()
	labelWidth := cols - 32
	if labelWidth < 12 {
		labelWidth = 12
	}

	linePrefix := fmt.Sprintf("%2d", index+1)
	target := fmt.Sprintf("%d.%d", currentRow.WindowIndex, currentRow.PaneIndex)
	line := fmt.Sprintf("%s  %s %-7s %-5s %s",
		linePrefix,
		stateBadge(currentRow.State),
		strings.ToLower(currentRow.Kind),
		target,
		truncateText(currentRow.Label, labelWidth),
	)

	if index == p.selectedIndex {
		return ansiBold + "> " + line + ansiReset + "\n"
	}

	return "  " + line + "\n"
}

func (p *Popup) renderSelectedDetails() string {
	if len(p.rows) == 0 || p.selectedIndex >= len(p.rows) {
		return ""
	}

	cols := p.screenWidth()
	labelWidth := cols - 16
	if labelWidth < 20 {
		labelWidth = 20
	}

	currentRow := p.rows[p.selectedIndex]
	var builder strings.Builder
	builder.WriteString("\n")

	builder.WriteString(ansiBold)
	builder.WriteString("Selected:")
	builder.WriteString(ansiReset)
	builder.WriteString(fmt.Sprintf(" %s:%d.%d  %s  [%s]\n",
		currentRow.SessionName,
		currentRow.WindowIndex,
		currentRow.PaneIndex,
		stateBadge(currentRow.State),
		strings.ToLower(currentRow.Kind),
	))

	builder.WriteString(ansiDim)
	builder.WriteString("Path:")
	builder.WriteString(ansiReset)
	builder.WriteString(" ")
	builder.WriteString(truncateText(currentRow.CurrentPath, labelWidth))
	builder.WriteString("\n")
	return builder.String()
}

func (p *Popup) projectSummary(projectName, currentSession string) projectSummary {
	summary := projectSummary{}

	for _, currentRow := range p.rows {
		if currentRow.SessionName != projectName {
			continue
		}

		summary.paneCount++
		if currentRow.SessionName == currentSession {
			summary.isCurrentProject = true
		}

		switch currentRow.State {
		case monitor.StateAttention:
			summary.attentionCount++
		case monitor.StateDone:
			summary.doneCount++
		case monitor.StateBusy:
			summary.busyCount++
		case monitor.StateCurrent:
			summary.currentCount++
		}
	}

	return summary
}

func (p *Popup) projectSummaryText(summary projectSummary) string {
	return fmt.Sprintf("%d %s | !%d input | D%d waiting | B%d busy | C%d current",
		summary.paneCount,
		paneWord(summary.paneCount),
		summary.attentionCount,
		summary.doneCount,
		summary.busyCount,
		summary.currentCount,
	)
}

func (p *Popup) globalSummaryLine() string {
	projectCount := 0
	attentionCount := 0
	doneCount := 0
	busyCount := 0
	currentCount := 0
	previousProject := ""

	for _, currentRow := range p.rows {
		if currentRow.SessionName != previousProject {
			projectCount++
			previousProject = currentRow.SessionName
		}

		switch currentRow.State {
		case monitor.StateAttention:
			attentionCount++
		case monitor.StateDone:
			doneCount++
		case monitor.StateBusy:
			busyCount++
		case monitor.StateCurrent:
			currentCount++
		}
	}

	line := fmt.Sprintf("%d %s | !%d input | D%d waiting | B%d busy",
		projectCount,
		projectWord(projectCount),
		attentionCount,
		doneCount,
		busyCount,
	)
	if currentCount > 0 {
		line += fmt.Sprintf(" | C%d current", currentCount)
	}
	return line
}

func (p *Popup) screenWidth() int {
	value, err := p.tmux.DisplayFormat("#{client_width}", "")
	if err != nil {
		return 80
	}

	width, err := strconv.Atoi(strings.TrimSpace(value))
	if err != nil || width < 40 {
		return 80
	}

	return width
}

func enterRawMode() (*os.File, *terminalState, error) {
	input, closeTTY, err := openTerminal()
	if err != nil {
		return nil, nil, err
	}

	cmd := exec.Command("stty", "-g")
	cmd.Stdin = input
	output, err := cmd.Output()
	if err != nil {
		if closeTTY {
			_ = input.Close()
		}
		return nil, nil, err
	}

	state := &terminalState{
		original: strings.TrimSpace(string(output)),
		tty:      input,
		closeTTY: closeTTY,
	}

	rawCmd := exec.Command("stty", "raw", "-echo", "min", "0", "time", "1")
	rawCmd.Stdin = input
	if err := rawCmd.Run(); err != nil {
		if closeTTY {
			_ = input.Close()
		}
		return nil, nil, err
	}

	return input, state, nil
}

func openTerminal() (*os.File, bool, error) {
	tty, err := os.OpenFile("/dev/tty", os.O_RDWR, 0)
	if err == nil {
		return tty, true, nil
	}

	if os.Stdin == nil {
		return nil, false, err
	}

	return os.Stdin, false, nil
}

func (t *terminalState) restore() {
	if t == nil || t.original == "" || t.tty == nil {
		return
	}

	cmd := exec.Command("stty", t.original)
	cmd.Stdin = t.tty
	_ = cmd.Run()
	if t.closeTTY {
		_ = t.tty.Close()
	}
}

func stateBadge(state monitor.State) string {
	text := stateBadgePlain(state)

	switch state {
	case monitor.StateAttention:
		return ansiYellow + text + ansiReset
	case monitor.StateDone:
		return ansiGreen + text + ansiReset
	case monitor.StateCurrent:
		return ansiCyan + text + ansiReset
	default:
		return ansiGray + text + ansiReset
	}
}

func stateBadgePlain(state monitor.State) string {
	switch state {
	case monitor.StateAttention:
		return "[! input]"
	case monitor.StateDone:
		return "[D wait]"
	case monitor.StateBusy:
		return "[B busy]"
	case monitor.StateCurrent:
		return "[C here]"
	default:
		return "[" + string(state) + "]"
	}
}

func truncateText(text string, width int) string {
	if width <= 3 {
		if len(text) <= width {
			return text
		}
		return text[:width]
	}

	if len(text) <= width {
		return text
	}

	return text[:width-3] + "..."
}

func projectWord(count int) string {
	if count == 1 {
		return "project"
	}
	return "projects"
}

func paneWord(count int) string {
	if count == 1 {
		return "pane"
	}
	return "panes"
}
