package monitor

import (
	"fmt"
	"hash/crc32"
	"path/filepath"
	"regexp"
	"strings"
)

type State string

const (
	StateAttention State = "attention"
	StateDone      State = "done"
	StateBusy      State = "busy"
	StateCurrent   State = "current"
)

type Classifier struct {
	attention *regexp.Regexp
	done      *regexp.Regexp
}

func NewClassifier(attentionPattern, attentionFallback, donePattern, doneFallback string) Classifier {
	return Classifier{
		attention: compileWithFallback(attentionPattern, attentionFallback),
		done:      compileWithFallback(donePattern, doneFallback),
	}
}

func (c Classifier) Classify(text string) State {
	if c.matchesAttention(text) {
		return StateAttention
	}
	if c.matchesDonePrompt(text) {
		return StateDone
	}
	return StateBusy
}

func (c Classifier) matchesAttention(text string) bool {
	if strings.TrimSpace(text) == "" {
		return false
	}
	tail := TailNonEmptyLines(text, 12)
	return c.attention != nil && c.attention.MatchString(tail)
}

func (c Classifier) matchesDonePrompt(text string) bool {
	tail := TailNonEmptyLines(text, 3)
	if strings.TrimSpace(tail) == "" {
		return false
	}
	return c.done != nil && c.done.MatchString(tail)
}

func TailNonEmptyLines(text string, limit int) string {
	if limit <= 0 {
		return ""
	}

	lines := strings.Split(text, "\n")
	nonEmpty := make([]string, 0, len(lines))
	for _, line := range lines {
		if strings.TrimSpace(line) != "" {
			nonEmpty = append(nonEmpty, line)
		}
	}

	if len(nonEmpty) > limit {
		nonEmpty = nonEmpty[len(nonEmpty)-limit:]
	}

	return strings.Join(nonEmpty, "\n")
}

func CaptureSignature(text string) string {
	lines := strings.Split(text, "\n")
	if len(lines) > 25 {
		lines = lines[len(lines)-25:]
	}

	sample := strings.Join(lines, "\n")
	sum := crc32.ChecksumIEEE([]byte(sample))
	return fmt.Sprintf("%08x:%d", sum, len(sample))
}

func ShouldNotifyForPane(paneActive, windowActive bool, sessionAttached int) bool {
	return !(sessionAttached > 0 && windowActive && paneActive)
}

func DisplayStateForPane(state State, paneActive, windowActive bool, sessionAttached int) State {
	if ShouldNotifyForPane(paneActive, windowActive, sessionAttached) {
		return state
	}
	return StateCurrent
}

func PaneCountWord(count int) string {
	if count == 1 {
		return "pane"
	}
	return "panes"
}

func KindLabel(kind string) string {
	switch kind {
	case "codex":
		return "Codex"
	case "claude":
		return "Claude"
	default:
		return kind
	}
}

func PaneStateBadge(state State) string {
	switch state {
	case StateAttention:
		return "#[fg=colour214 bold]! input#[default]"
	case StateDone:
		return "#[fg=colour42]D waiting#[default]"
	case StateBusy:
		return "#[fg=colour245]B busy#[default]"
	case StateCurrent:
		return "#[fg=colour39 bold]C current#[default]"
	default:
		return string(state)
	}
}

func SummaryBadge(attentionCount, doneCount, busyCount, currentCount, paneCount int) string {
	parts := make([]string, 0, 5)
	if attentionCount > 0 {
		parts = append(parts, fmt.Sprintf("#[fg=colour214 bold]!%d#[default]", attentionCount))
	}
	if doneCount > 0 {
		parts = append(parts, fmt.Sprintf("#[fg=colour42]D%d#[default]", doneCount))
	}
	if busyCount > 0 {
		parts = append(parts, fmt.Sprintf("#[fg=colour245]B%d#[default]", busyCount))
	}
	if currentCount > 0 {
		parts = append(parts, fmt.Sprintf("#[fg=colour39 bold]C%d#[default]", currentCount))
	}
	parts = append(parts, fmt.Sprintf("#[fg=colour244](%d %s)#[default]", paneCount, PaneCountWord(paneCount)))
	return strings.Join(parts, " ")
}

func PaneItemLabel(windowName, paneTitle, paneCurrentPath string) string {
	baseName := ""
	if paneCurrentPath != "" {
		baseName = filepath.Base(paneCurrentPath)
	}

	label := ""
	switch {
	case windowName != "":
		label = windowName
	case baseName != "":
		label = baseName
	}

	if paneTitle != "" && paneTitle != windowName {
		if label != "" {
			label += " - " + paneTitle
		} else {
			label = paneTitle
		}
	}

	if label == "" {
		label = paneCurrentPath
	}

	return label
}

func PaneLabel(sessionName string, windowIndex, paneIndex int, paneTitle string) string {
	label := fmt.Sprintf("%s:%d.%d", sessionName, windowIndex, paneIndex)
	if paneTitle == "" {
		return label
	}
	return fmt.Sprintf("%s (%s)", label, paneTitle)
}

func StatusText(attentionCount, doneCount int) string {
	if attentionCount == 0 && doneCount == 0 {
		return ""
	}

	parts := []string{"#[fg=colour39 bold]AI#[default]"}
	if attentionCount > 0 {
		parts = append(parts, fmt.Sprintf("#[fg=colour214 bold]!%d#[default]", attentionCount))
	}
	if doneCount > 0 {
		parts = append(parts, fmt.Sprintf("#[fg=colour42]D%d#[default]", doneCount))
	}
	return strings.Join(parts, " ")
}

func StateRank(state State) int {
	switch state {
	case StateAttention:
		return 0
	case StateDone:
		return 1
	case StateBusy:
		return 2
	case StateCurrent:
		return 3
	default:
		return 9
	}
}

func PaneKey(paneID string) string {
	paneID = strings.TrimPrefix(paneID, "%")
	var builder strings.Builder
	for _, r := range paneID {
		if r >= '0' && r <= '9' {
			builder.WriteRune(r)
		}
	}
	return builder.String()
}

func compileWithFallback(pattern, fallback string) *regexp.Regexp {
	for _, candidate := range []string{pattern, fallback} {
		if candidate == "" {
			continue
		}
		re, err := regexp.Compile("(?im)" + candidate)
		if err == nil {
			return re
		}
	}
	return nil
}
