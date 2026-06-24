package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
	"time"
)

const approvedCommandsFile = "approved_commands.json"

// sandboxCommand is a function variable for exec.CommandContext, replaceable in tests.
var sandboxCommand = exec.CommandContext

type hostSandboxBashRunner struct {
	workspace string
}

func (r hostSandboxBashRunner) RunBash(ctx context.Context, opts bashRunOptions) (CommandResult, error) {
	if r.workspace == "" {
		return CommandResult{}, fmt.Errorf("workspace not configured")
	}
	workspace, err := filepath.Abs(r.workspace)
	if err != nil {
		return CommandResult{}, fmt.Errorf("resolving workspace: %w", err)
	}
	if err := prepareNakedWorkspaceDirs(workspace); err != nil {
		return CommandResult{}, err
	}

	timeout := opts.timeout
	if timeout <= 0 {
		timeout = 120
	}
	parent := ctx
	if parent == nil {
		parent = context.Background()
	}
	runCtx, cancel := context.WithTimeout(parent, time.Duration(timeout)*time.Second)
	defer cancel()

	name, args, env, err := nakedSandboxCommand(nakedSandboxCommandOptions{
		goos:      runtime.GOOS,
		workspace: workspace,
		command:   opts.command,
	})
	if err != nil {
		return CommandResult{}, err
	}

	cmd := sandboxCommand(runCtx, name, args...)
	cmd.Dir = workspace
	if len(env) > 0 {
		cmd.Env = append(os.Environ(), env...)
	}
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	err = cmd.Run()
	result := CommandResult{
		Stdout: stdout.String(),
		Stderr: stderr.String(),
	}
	if exitErr, ok := err.(*exec.ExitError); ok {
		result.ExitCode = exitErr.ExitCode()
		return result, nil
	}
	if err != nil {
		if runCtx.Err() == context.DeadlineExceeded {
			return CommandResult{}, fmt.Errorf("command timed out after %ds", timeout)
		}
		return CommandResult{}, fmt.Errorf("host sandbox exec: %w", err)
	}
	return result, nil
}

func prepareNakedWorkspaceDirs(workspace string) error {
	for _, dir := range []string{
		filepath.Join(workspace, configDir),
		filepath.Join(workspace, configDir, "home"),
		filepath.Join(workspace, configDir, "cache"),
		filepath.Join(workspace, configDir, "tmp"),
	} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return fmt.Errorf("creating naked workspace dir %s: %w", dir, err)
		}
	}
	return nil
}

type nakedSandboxCommandOptions struct {
	goos      string
	workspace string
	command   string
}

func nakedSandboxCommand(opts nakedSandboxCommandOptions) (name string, args []string, env []string, err error) {
	switch opts.goos {
	case "linux":
		return linuxNakedSandboxCommand(opts.workspace, opts.command)
	case "darwin":
		return darwinNakedSandboxCommand(opts.workspace, opts.command)
	default:
		return "", nil, nil, fmt.Errorf("--naked sandboxing is unsupported on %s", opts.goos)
	}
}

func checkNakedSandboxAvailable() error {
	switch runtime.GOOS {
	case "linux":
		if _, err := lookPath("bwrap"); err != nil {
			return fmt.Errorf("bubblewrap (bwrap) is required for --naked on Linux")
		}
		return nil
	case "darwin":
		if _, err := lookPath("sandbox-exec"); err != nil {
			return fmt.Errorf("sandbox-exec is required for --naked on macOS")
		}
		return nil
	default:
		return fmt.Errorf("--naked sandboxing is unsupported on %s", runtime.GOOS)
	}
}

func linuxNakedSandboxCommand(workspace, command string) (string, []string, []string, error) {
	bwrapPath, err := lookPath("bwrap")
	if err != nil {
		return "", nil, nil, fmt.Errorf("bubblewrap (bwrap) is required for --naked on Linux")
	}

	homeDir := filepath.Join(workspace, configDir, "home")
	cacheDir := filepath.Join(workspace, configDir, "cache")
	tmpDir := filepath.Join(workspace, configDir, "tmp")

	args := []string{
		"--die-with-parent",
		"--unshare-all",
		"--share-net",
		"--new-session",
		"--proc", "/proc",
		"--dev", "/dev",
		"--tmpfs", "/tmp",
		"--setenv", "HOME", homeDir,
		"--setenv", "XDG_CACHE_HOME", cacheDir,
		"--setenv", "TMPDIR", tmpDir,
	}

	for _, path := range linuxReadOnlySandboxPaths() {
		args = append(args, "--ro-bind", path, path)
	}
	for _, dir := range sandboxParentDirs(workspace) {
		args = append(args, "--dir", dir)
	}

	args = append(args,
		"--bind", workspace, workspace,
		"--chdir", workspace,
		"bash", "-lc", command,
	)
	return bwrapPath, args, nil, nil
}

func linuxReadOnlySandboxPaths() []string {
	candidates := []string{"/bin", "/sbin", "/usr", "/lib", "/lib64", "/etc", "/opt", "/nix"}
	var paths []string
	for _, path := range candidates {
		if _, err := os.Stat(path); err == nil {
			paths = append(paths, path)
		}
	}
	return paths
}

func sandboxParentDirs(path string) []string {
	cleaned := filepath.Clean(path)
	var dirs []string
	for {
		if cleaned == string(filepath.Separator) || cleaned == "." {
			break
		}
		dirs = append(dirs, cleaned)
		parent := filepath.Dir(cleaned)
		if parent == cleaned {
			break
		}
		cleaned = parent
	}
	for i, j := 0, len(dirs)-1; i < j; i, j = i+1, j-1 {
		dirs[i], dirs[j] = dirs[j], dirs[i]
	}
	return dirs
}

func darwinNakedSandboxCommand(workspace, command string) (string, []string, []string, error) {
	sandboxExecPath, err := lookPath("sandbox-exec")
	if err != nil {
		return "", nil, nil, fmt.Errorf("sandbox-exec is required for --naked on macOS")
	}
	profile := darwinNakedSandboxProfile(workspace)
	env := []string{
		"HOME=" + filepath.Join(workspace, configDir, "home"),
		"XDG_CACHE_HOME=" + filepath.Join(workspace, configDir, "cache"),
		"TMPDIR=" + filepath.Join(workspace, configDir, "tmp"),
	}
	return sandboxExecPath, []string{"-p", profile, "bash", "-lc", command}, env, nil
}

func darwinNakedSandboxProfile(workspace string) string {
	quoted := sandboxProfileQuote(workspace)
	return fmt.Sprintf(`(version 1)
(deny default)
(allow process*)
(allow signal)
(allow sysctl-read)
(allow mach-lookup)
(allow network*)
(allow file-read*)
(allow file-write* (subpath %s))
`, quoted)
}

func sandboxProfileQuote(s string) string {
	escaped := strings.ReplaceAll(s, `\`, `\\`)
	escaped = strings.ReplaceAll(escaped, `"`, `\"`)
	return `"` + escaped + `"`
}

func nakedApprovedCommandsPath(workspace string) string {
	return filepath.Join(workspace, configDir, approvedCommandsFile)
}

type approvedCommandStore struct {
	path string
	mu   sync.Mutex
}

func newApprovedCommandStore(path string) *approvedCommandStore {
	if path == "" {
		return nil
	}
	return &approvedCommandStore{path: path}
}

type approvedCommandFile struct {
	Version  int      `json:"version"`
	Commands []string `json:"commands"`
}

func (s *approvedCommandStore) RequiresApproval(command string) bool {
	if s == nil || strings.TrimSpace(command) == "" {
		return false
	}
	approved, err := s.load()
	if err != nil {
		return true
	}
	for _, segment := range commandApprovalSegments(command) {
		if !approved[segment] {
			return true
		}
	}
	return false
}

func (s *approvedCommandStore) RecordApproval(command string) error {
	if s == nil || strings.TrimSpace(command) == "" {
		return nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	approved, err := s.loadLocked()
	if err != nil {
		return err
	}
	changed := false
	for _, segment := range commandApprovalSegments(command) {
		if !approved[segment] {
			approved[segment] = true
			changed = true
		}
	}
	if !changed {
		return nil
	}
	return s.saveLocked(approved)
}

func (s *approvedCommandStore) load() (map[string]bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.loadLocked()
}

func (s *approvedCommandStore) loadLocked() (map[string]bool, error) {
	approved := map[string]bool{}
	data, err := os.ReadFile(s.path)
	if os.IsNotExist(err) {
		return approved, nil
	}
	if err != nil {
		return approved, err
	}
	var file approvedCommandFile
	if err := json.Unmarshal(data, &file); err != nil {
		return approved, err
	}
	for _, command := range file.Commands {
		command = strings.TrimSpace(command)
		if command != "" {
			approved[command] = true
		}
	}
	return approved, nil
}

func (s *approvedCommandStore) saveLocked(approved map[string]bool) error {
	commands := make([]string, 0, len(approved))
	for command := range approved {
		commands = append(commands, command)
	}
	sort.Strings(commands)
	data, err := json.MarshalIndent(approvedCommandFile{Version: 1, Commands: commands}, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(s.path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(s.path, append(data, '\n'), 0o644)
}

func commandApprovalSegments(command string) []string {
	var segments []string
	var b strings.Builder
	var quote rune
	escaped := false
	skipNext := false
	flush := func() {
		segment := strings.TrimSpace(b.String())
		if segment != "" {
			segments = append(segments, segment)
		}
		b.Reset()
	}

	for i, r := range command {
		if skipNext {
			skipNext = false
			continue
		}
		if escaped {
			b.WriteRune(r)
			escaped = false
			continue
		}
		if r == '\\' && quote != '\'' {
			b.WriteRune(r)
			escaped = true
			continue
		}
		if quote != 0 {
			b.WriteRune(r)
			if r == quote {
				quote = 0
			}
			continue
		}
		if r == '\'' || r == '"' {
			quote = r
			b.WriteRune(r)
			continue
		}
		switch r {
		case '\n', ';', '|':
			flush()
			if r == '|' && i+1 < len(command) && command[i+1] == '|' {
				skipNext = true
			}
			continue
		case '&':
			if i+1 < len(command) && command[i+1] == '&' {
				flush()
				skipNext = true
				continue
			}
		case '(', ')':
			flush()
			continue
		}
		b.WriteRune(r)
	}
	flush()
	if len(segments) == 0 {
		if trimmed := strings.TrimSpace(command); trimmed != "" {
			return []string{trimmed}
		}
	}
	return segments
}
