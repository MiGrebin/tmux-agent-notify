package monitor

import "testing"

func TestClassifierClassifiesAttention(t *testing.T) {
	classifier := NewClassifier(`approve|continue\?`, `approve`, `^[[:space:]]*[›>][[:space:]]`, `^[[:space:]]*[›>][[:space:]]`)
	text := "working\nWould you like to run the following command?\napprove"

	state := classifier.Classify(text)
	if state != StateAttention {
		t.Fatalf("expected attention, got %s", state)
	}
}

func TestClassifierClassifiesDonePrompt(t *testing.T) {
	classifier := NewClassifier(`approve`, `approve`, `^[[:space:]]*[›>][[:space:]]`, `^[[:space:]]*[›>][[:space:]]`)
	text := "Finished work\n\n› "

	state := classifier.Classify(text)
	if state != StateDone {
		t.Fatalf("expected done, got %s", state)
	}
}

func TestDisplayStateForPaneMarksCurrentPane(t *testing.T) {
	state := DisplayStateForPane(StateAttention, true, true, 1)
	if state != StateCurrent {
		t.Fatalf("expected current, got %s", state)
	}
}

func TestPaneItemLabelPrefersWindowAndTitle(t *testing.T) {
	label := PaneItemLabel("editor", "codex", "/tmp/project")
	if label != "editor - codex" {
		t.Fatalf("unexpected label %q", label)
	}
}
