package notify

import (
	"fmt"
	"os/exec"
	"strings"

	"github.com/MiGrebin/tmux-agent-notify/internal/tmuxcli"
)

type Notifier struct {
	tmux           *tmuxcli.Client
	useAppleScript bool
}

func New(tmux *tmuxcli.Client) *Notifier {
	_, err := exec.LookPath("osascript")
	return &Notifier{
		tmux:           tmux,
		useAppleScript: err == nil,
	}
}

func (n *Notifier) Notify(kind, state, label string) {
	title := titleForKind(kind)
	switch kind {
	case "codex":
		title = "Codex"
	case "claude":
		title = "Claude"
	}

	switch state {
	case "attention":
		n.Send(title, fmt.Sprintf("%s needs input", label))
	case "done":
		n.Send(title, fmt.Sprintf("%s is waiting for you", label))
	}
}

func (n *Notifier) Send(title, message string) {
	if n.useAppleScript {
		script := fmt.Sprintf(`display notification "%s" with title "%s"`, escapeAppleScript(message), escapeAppleScript(title))
		if err := exec.Command("osascript", "-e", script).Run(); err == nil {
			return
		}
	}

	_ = n.tmux.DisplayMessage(fmt.Sprintf("%s: %s", title, message))
}

func escapeAppleScript(value string) string {
	replacer := strings.NewReplacer(`\`, `\\`, `"`, `\"`)
	return replacer.Replace(value)
}

func titleForKind(value string) string {
	if value == "" {
		return ""
	}

	lower := strings.ToLower(value)
	return strings.ToUpper(lower[:1]) + lower[1:]
}
