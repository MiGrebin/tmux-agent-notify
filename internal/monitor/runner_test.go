package monitor

import "testing"

func TestSocketPathFromEnvParsesTMUXValue(t *testing.T) {
	value := "/private/tmp/tmux-501/default,42536,0"
	got := socketPathFromEnv(value)

	if got != "/private/tmp/tmux-501/default" {
		t.Fatalf("unexpected socket path %q", got)
	}
}

func TestSocketPathFromEnvHandlesPlainPath(t *testing.T) {
	value := "/tmp/custom-tmux.sock"
	got := socketPathFromEnv(value)

	if got != value {
		t.Fatalf("unexpected socket path %q", got)
	}
}
