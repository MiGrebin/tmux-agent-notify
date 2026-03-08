package agent

import (
	"os/exec"
	"regexp"
	"strconv"
	"strings"
)

type Kind string

const (
	KindCodex  Kind = "codex"
	KindClaude Kind = "claude"
)

type Process struct {
	PID     int
	PPID    int
	Command string
}

type Snapshot struct {
	children map[int][]Process
}

type Detector struct {
	re *regexp.Regexp
}

func NewDetector(pattern, fallback string) Detector {
	return Detector{re: compileWithFallback(pattern, fallback)}
}

func ScanSnapshot() (Snapshot, error) {
	cmd := exec.Command("ps", "-axo", "pid=,ppid=,command=")
	output, err := cmd.Output()
	if err != nil {
		return Snapshot{children: map[int][]Process{}}, err
	}

	children := make(map[int][]Process)
	for _, line := range strings.Split(strings.TrimRight(string(output), "\n"), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}

		fields := strings.Fields(line)
		if len(fields) < 3 {
			continue
		}

		pid, err := strconv.Atoi(fields[0])
		if err != nil {
			continue
		}

		ppid, err := strconv.Atoi(fields[1])
		if err != nil {
			continue
		}

		commandStart := strings.Index(line, fields[2])
		if commandStart < 0 {
			continue
		}

		process := Process{
			PID:     pid,
			PPID:    ppid,
			Command: strings.TrimSpace(line[commandStart:]),
		}
		children[ppid] = append(children[ppid], process)
	}

	return Snapshot{children: children}, nil
}

func (d Detector) KindForPane(snapshot Snapshot, panePID int, paneTitle string) (Kind, bool) {
	if command, ok := snapshot.firstMatch(panePID, d.re); ok {
		return kindForText(command), true
	}

	if paneTitle == "" {
		return "", false
	}

	title := strings.ToLower(paneTitle)
	switch {
	case strings.Contains(title, string(KindClaude)):
		return KindClaude, true
	case strings.Contains(title, string(KindCodex)):
		return KindCodex, true
	default:
		return "", false
	}
}

func (s Snapshot) firstMatch(rootPID int, re *regexp.Regexp) (string, bool) {
	if re == nil || rootPID <= 0 {
		return "", false
	}

	stack := []int{rootPID}
	seen := map[int]bool{}

	for len(stack) > 0 {
		last := len(stack) - 1
		pid := stack[last]
		stack = stack[:last]

		if seen[pid] {
			continue
		}
		seen[pid] = true

		for _, child := range s.children[pid] {
			if re.MatchString(child.Command) {
				return child.Command, true
			}
			stack = append(stack, child.PID)
		}
	}

	return "", false
}

func compileWithFallback(pattern, fallback string) *regexp.Regexp {
	for _, candidate := range []string{pattern, fallback} {
		if candidate == "" {
			continue
		}
		re, err := regexp.Compile("(?i)" + candidate)
		if err == nil {
			return re
		}
	}
	return nil
}

func kindForText(command string) Kind {
	if strings.Contains(strings.ToLower(command), string(KindClaude)) {
		return KindClaude
	}
	return KindCodex
}
