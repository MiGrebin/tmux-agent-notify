package agent

import "testing"

func TestDetectorMatchesDescendantProcess(t *testing.T) {
	detector := NewDetector(`(/bin/codex|/@openai/codex|claude)`, `codex|claude`)
	snapshot := Snapshot{
		children: map[int][]Process{
			100: {
				{PID: 101, PPID: 100, Command: "/bin/zsh"},
			},
			101: {
				{PID: 102, PPID: 101, Command: "node /tmp/bin/codex"},
			},
		},
	}

	kind, ok := detector.KindForPane(snapshot, 100, "")
	if !ok {
		t.Fatalf("expected detector to match descendant process")
	}
	if kind != KindCodex {
		t.Fatalf("expected codex, got %s", kind)
	}
}

func TestDetectorFallsBackToPaneTitle(t *testing.T) {
	detector := NewDetector(`codex|claude`, `codex|claude`)
	snapshot := Snapshot{children: map[int][]Process{}}

	kind, ok := detector.KindForPane(snapshot, 100, "Claude Code")
	if !ok {
		t.Fatalf("expected detector to match pane title")
	}
	if kind != KindClaude {
		t.Fatalf("expected claude, got %s", kind)
	}
}
