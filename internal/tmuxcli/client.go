package tmuxcli

import (
	"errors"
	"fmt"
	"os/exec"
	"strconv"
	"strings"
)

const (
	separator        = "\x1f"
	escapedSeparator = `\037`
)

type Client struct {
	Binary string
}

type Pane struct {
	ID              string
	PID             int
	SessionName     string
	WindowIndex     int
	PaneIndex       int
	PaneActive      bool
	WindowActive    bool
	SessionAttached int
	Title           string
	CurrentPath     string
	WindowName      string
}

type AgentPane struct {
	ID          string
	KindLabel   string
	State       string
	SessionName string
	WindowIndex int
	PaneIndex   int
	Label       string
	CurrentPath string
}

func New() *Client {
	return &Client{Binary: "tmux"}
}

func (c *Client) run(args ...string) error {
	cmd := exec.Command(c.Binary, args...)
	return cmd.Run()
}

func (c *Client) output(args ...string) (string, error) {
	cmd := exec.Command(c.Binary, args...)
	out, err := cmd.Output()
	if err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			return strings.TrimRight(string(exitErr.Stderr), "\n"), err
		}
		return "", err
	}

	return strings.TrimRight(string(out), "\n"), nil
}

func (c *Client) Option(name, defaultValue string) string {
	value, err := c.output("show-option", "-gqv", name)
	if err != nil || value == "" {
		return defaultValue
	}
	return value
}

func (c *Client) SetOption(name, value string) error {
	return c.run("set-option", "-gq", name, value)
}

func (c *Client) UnsetOption(name string) error {
	return c.run("set-option", "-gu", name)
}

func (c *Client) SetTargetOption(scope, target, option, value string) error {
	switch scope {
	case "pane":
		return c.run("set-option", "-pq", "-t", target, option, value)
	case "window":
		return c.run("set-option", "-wq", "-t", target, option, value)
	case "session":
		return c.run("set-option", "-q", "-t", target, option, value)
	default:
		return fmt.Errorf("unsupported tmux scope %q", scope)
	}
}

func (c *Client) BindKey(key, command string) error {
	return c.run("bind-key", key, "run-shell", command)
}

func (c *Client) DisplayMessage(message string) error {
	return c.run("display-message", message)
}

func (c *Client) RefreshClient() error {
	return c.run("refresh-client", "-S")
}

func (c *Client) DisplayFormat(format, target string) (string, error) {
	args := []string{"display-message", "-p"}
	if target != "" {
		args = append(args, "-t", target)
	}
	args = append(args, format)
	return c.output(args...)
}

func (c *Client) CurrentPaneID() (string, error) {
	return c.DisplayFormat("#{pane_id}", "")
}

func (c *Client) CurrentSessionName() (string, error) {
	return c.DisplayFormat("#S", "")
}

func (c *Client) SocketPath() (string, error) {
	return c.DisplayFormat("#{socket_path}", "")
}

func (c *Client) DisplayPopup(width, height, title, command string) error {
	return c.run("display-popup", "-E", "-w", width, "-h", height, "-T", title, command)
}

func (c *Client) ChooseTree(targetPane, filter, format, template string) error {
	return c.run("choose-tree", "-t", targetPane, "-N", "-Z", "-O", "name", "-f", filter, "-F", format, template)
}

func (c *Client) PaneTarget(paneID string) (string, error) {
	return c.DisplayFormat("#{session_name}:#{window_index}", paneID)
}

func (c *Client) SwitchToPane(paneID string) error {
	target, err := c.PaneTarget(paneID)
	if err != nil || target == "" {
		return fmt.Errorf("tmux pane %s is unavailable", paneID)
	}

	sessionName, _, found := strings.Cut(target, ":")
	if !found {
		return fmt.Errorf("unexpected tmux pane target %q", target)
	}

	if err := c.run("switch-client", "-t", sessionName); err != nil {
		return err
	}
	if err := c.run("select-window", "-t", target); err != nil {
		return err
	}
	return c.run("select-pane", "-t", paneID)
}

func (c *Client) CapturePane(paneID string, lines int) (string, error) {
	if lines <= 0 {
		lines = 80
	}
	return c.output("capture-pane", "-p", "-t", paneID, "-S", fmt.Sprintf("-%d", lines))
}

func (c *Client) ListPanesAll() ([]Pane, error) {
	format := strings.Join([]string{
		"#{pane_id}",
		"#{pane_pid}",
		"#{session_name}",
		"#{window_index}",
		"#{pane_index}",
		"#{pane_active}",
		"#{window_active}",
		"#{session_attached}",
		"#{pane_title}",
		"#{pane_current_path}",
		"#{window_name}",
	}, separator)

	output, err := c.output("list-panes", "-a", "-F", format)
	if err != nil {
		return nil, err
	}

	lines := splitLines(output)
	panes := make([]Pane, 0, len(lines))
	for _, line := range lines {
		fields := splitStructuredFields(line)
		if len(fields) != 11 {
			continue
		}

		panes = append(panes, Pane{
			ID:              fields[0],
			PID:             parseInt(fields[1]),
			SessionName:     fields[2],
			WindowIndex:     parseInt(fields[3]),
			PaneIndex:       parseInt(fields[4]),
			PaneActive:      fields[5] == "1",
			WindowActive:    fields[6] == "1",
			SessionAttached: parseInt(fields[7]),
			Title:           fields[8],
			CurrentPath:     fields[9],
			WindowName:      fields[10],
		})
	}

	return panes, nil
}

func (c *Client) ListAgentPanes() ([]AgentPane, error) {
	format := strings.Join([]string{
		"#{pane_id}",
		"#{@agent_notify_pane_kind_label}",
		"#{@agent_notify_pane_state}",
		"#{session_name}",
		"#{window_index}",
		"#{pane_index}",
		"#{@agent_notify_pane_label}",
		"#{pane_current_path}",
	}, separator)

	output, err := c.output("list-panes", "-a", "-f", "#{==:#{@agent_notify_is_agent},1}", "-F", format)
	if err != nil {
		return nil, err
	}

	lines := splitLines(output)
	panes := make([]AgentPane, 0, len(lines))
	for _, line := range lines {
		fields := splitStructuredFields(line)
		if len(fields) != 8 {
			continue
		}

		panes = append(panes, AgentPane{
			ID:          fields[0],
			KindLabel:   fields[1],
			State:       fields[2],
			SessionName: fields[3],
			WindowIndex: parseInt(fields[4]),
			PaneIndex:   parseInt(fields[5]),
			Label:       fields[6],
			CurrentPath: fields[7],
		})
	}

	return panes, nil
}

func (c *Client) ListPaneIDs(filter string) ([]string, error) {
	return c.listValues("list-panes", []string{"-a", "-f", filter, "-F", "#{pane_id}"})
}

func (c *Client) ListWindowTargets(filter string) ([]string, error) {
	return c.listValues("list-windows", []string{"-a", "-f", filter, "-F", "#{session_name}:#{window_index}"})
}

func (c *Client) ListSessionNames(filter string) ([]string, error) {
	return c.listValues("list-sessions", []string{"-f", filter, "-F", "#{session_name}"})
}

func (c *Client) listValues(command string, args []string) ([]string, error) {
	output, err := c.output(append([]string{command}, args...)...)
	if err != nil {
		return nil, err
	}
	return splitLines(output), nil
}

func parseInt(value string) int {
	n, _ := strconv.Atoi(strings.TrimSpace(value))
	return n
}

func splitLines(value string) []string {
	if value == "" {
		return nil
	}

	parts := strings.Split(value, "\n")
	lines := make([]string, 0, len(parts))
	for _, part := range parts {
		if part != "" {
			lines = append(lines, part)
		}
	}
	return lines
}

func splitStructuredFields(value string) []string {
	if strings.Contains(value, separator) {
		return strings.Split(value, separator)
	}
	if strings.Contains(value, escapedSeparator) {
		return strings.Split(value, escapedSeparator)
	}
	return []string{value}
}
