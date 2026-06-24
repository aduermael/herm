// naked.go implements host sandboxing and permissions for naked mode.
package main

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"
)

const nakedPermissionsFile = "permissions.json"

// sandboxCommand is a function variable for exec.CommandContext, replaceable in tests.
var sandboxCommand = exec.CommandContext

// hostCommand is used for approval-gated naked commands that explicitly bypass
// the workspace sandbox.
var hostCommand = exec.CommandContext

type hostSandboxBashRunner struct {
	workspace   string
	permissions *nakedPermissionStore
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
	if r.permissions != nil {
		defer r.permissions.FinishRequestedPermissionsOnce()
	}

	if opts.sandboxPermissions == bashSandboxPermissionsRequireEscalated {
		return runUnsandboxedHostBash(runUnsandboxedHostBashOptions{
			ctx:       runCtx,
			workspace: workspace,
			command:   opts.command,
		})
	}

	var browserOpenLog string
	var browserBroker *darwinBrowserOpenBroker
	if runtime.GOOS == "darwin" {
		if err := writeDarwinBrowserOpenShim(workspace); err != nil {
			return CommandResult{}, err
		}
		browserOpenLog = filepath.Join(workspace, configDir, "tmp", fmt.Sprintf("browser-open-%d.log", time.Now().UnixNano()))
		browserBroker = startDarwinBrowserOpenBroker(browserOpenLog)
		defer browserBroker.Stop()
	}

	var extraPaths []string
	if r.permissions != nil {
		extraPaths = r.permissions.AllowedExternalPaths(opts.command)
	}
	var requestedReadPaths, requestedWritePaths []string
	var requestedNetwork bool
	if r.permissions != nil {
		requestedReadPaths, requestedWritePaths, requestedNetwork = r.permissions.RequestedSandboxPermissions()
	}
	additionalReadPaths, additionalWritePaths := opts.additionalPermissions.fileSystemPaths()
	name, args, env, err := nakedSandboxCommand(nakedSandboxCommandOptions{
		goos:            runtime.GOOS,
		workspace:       workspace,
		command:         opts.command,
		extraReadPaths:  append(requestedReadPaths, additionalReadPaths...),
		extraWritePaths: append(append(extraPaths, requestedWritePaths...), additionalWritePaths...),
		networkEnabled:  requestedNetwork || opts.additionalPermissions.Network.Enabled,
		openLog:         browserOpenLog,
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
	if browserBroker != nil {
		browserBroker.Stop()
		if brokerErrs := browserBroker.Errors(); brokerErrs != "" {
			if result.Stderr != "" && !strings.HasSuffix(result.Stderr, "\n") {
				result.Stderr += "\n"
			}
			result.Stderr += brokerErrs
		}
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

type runUnsandboxedHostBashOptions struct {
	ctx       context.Context
	workspace string
	command   string
}

func runUnsandboxedHostBash(opts runUnsandboxedHostBashOptions) (CommandResult, error) {
	cmd := hostCommand(opts.ctx, "bash", "-lc", opts.command)
	cmd.Dir = opts.workspace
	cmd.Env = append(os.Environ(), nakedWorkspaceEnv(opts.workspace)...)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	err := cmd.Run()
	result := CommandResult{
		Stdout: stdout.String(),
		Stderr: stderr.String(),
	}
	if exitErr, ok := err.(*exec.ExitError); ok {
		result.ExitCode = exitErr.ExitCode()
		return result, nil
	}
	if err != nil {
		return CommandResult{}, fmt.Errorf("host exec: %w", err)
	}
	return result, nil
}

func prepareNakedWorkspaceDirs(workspace string) error {
	for _, dir := range []string{
		filepath.Join(workspace, configDir),
		filepath.Join(workspace, configDir, "home"),
		filepath.Join(workspace, configDir, "bin"),
		filepath.Join(workspace, configDir, "cache"),
		filepath.Join(workspace, configDir, "tmp"),
	} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return fmt.Errorf("creating naked workspace dir %s: %w", dir, err)
		}
	}
	return nil
}

func nakedWorkspaceEnv(workspace string) []string {
	return []string{
		"HOME=" + filepath.Join(workspace, configDir, "home"),
		"XDG_CACHE_HOME=" + filepath.Join(workspace, configDir, "cache"),
		"TMPDIR=" + filepath.Join(workspace, configDir, "tmp"),
	}
}

type nakedSandboxCommandOptions struct {
	goos            string
	workspace       string
	command         string
	extraReadPaths  []string
	extraWritePaths []string
	networkEnabled  bool
	openLog         string
}

func nakedSandboxCommand(opts nakedSandboxCommandOptions) (name string, args []string, env []string, err error) {
	switch opts.goos {
	case "linux":
		return linuxNakedSandboxCommand(linuxNakedSandboxCommandOptions{
			workspace:       opts.workspace,
			command:         opts.command,
			extraReadPaths:  opts.extraReadPaths,
			extraWritePaths: opts.extraWritePaths,
			networkEnabled:  opts.networkEnabled,
		})
	case "darwin":
		return darwinNakedSandboxCommand(darwinNakedSandboxCommandOptions{
			workspace:       opts.workspace,
			command:         opts.command,
			extraReadPaths:  opts.extraReadPaths,
			extraWritePaths: opts.extraWritePaths,
			networkEnabled:  opts.networkEnabled,
			openLog:         opts.openLog,
		})
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

type linuxNakedSandboxCommandOptions struct {
	workspace       string
	command         string
	extraReadPaths  []string
	extraWritePaths []string
	networkEnabled  bool
}

func linuxNakedSandboxCommand(opts linuxNakedSandboxCommandOptions) (string, []string, []string, error) {
	bwrapPath, err := lookPath("bwrap")
	if err != nil {
		return "", nil, nil, fmt.Errorf("bubblewrap (bwrap) is required for --naked on Linux")
	}

	homeDir := filepath.Join(opts.workspace, configDir, "home")
	cacheDir := filepath.Join(opts.workspace, configDir, "cache")
	tmpDir := filepath.Join(opts.workspace, configDir, "tmp")

	args := []string{
		"--die-with-parent",
		"--unshare-all",
		"--new-session",
		"--proc", "/proc",
		"--dev", "/dev",
		"--tmpfs", "/tmp",
		"--setenv", "HOME", homeDir,
		"--setenv", "XDG_CACHE_HOME", cacheDir,
		"--setenv", "TMPDIR", tmpDir,
	}
	if opts.networkEnabled {
		args = append(args, "--share-net")
	}

	for _, path := range linuxReadOnlySandboxPaths() {
		args = append(args, "--ro-bind", path, path)
	}
	for _, dir := range sandboxParentDirs(opts.workspace) {
		args = append(args, "--dir", dir)
	}
	writePaths := normalizeNakedExternalPaths(normalizeNakedExternalPathsOptions{workspace: opts.workspace, paths: opts.extraWritePaths})
	writePathSet := map[string]bool{}
	for _, path := range writePaths {
		writePathSet[path] = true
	}
	for _, path := range normalizeNakedExternalPaths(normalizeNakedExternalPathsOptions{workspace: opts.workspace, paths: opts.extraReadPaths}) {
		if writePathSet[path] {
			continue
		}
		args = appendLinuxNakedPathBind(appendLinuxNakedPathBindOptions{args: args, bindFlag: "--ro-bind", path: path})
	}
	for _, path := range writePaths {
		args = appendLinuxNakedPathBind(appendLinuxNakedPathBindOptions{args: args, bindFlag: "--bind", path: path})
	}

	args = append(args,
		"--bind", opts.workspace, opts.workspace,
		"--chdir", opts.workspace,
		"bash", "-lc", opts.command,
	)
	return bwrapPath, args, nil, nil
}

type appendLinuxNakedPathBindOptions struct {
	args     []string
	bindFlag string
	path     string
}

func appendLinuxNakedPathBind(opts appendLinuxNakedPathBindOptions) []string {
	info, err := os.Stat(opts.path)
	if err != nil {
		return opts.args
	}
	parentPath := filepath.Dir(opts.path)
	if info.IsDir() {
		parentPath = opts.path
	}
	for _, dir := range sandboxParentDirs(parentPath) {
		opts.args = append(opts.args, "--dir", dir)
	}
	return append(opts.args, opts.bindFlag, opts.path, opts.path)
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

type darwinNakedSandboxCommandOptions struct {
	workspace       string
	command         string
	extraReadPaths  []string
	extraWritePaths []string
	networkEnabled  bool
	openLog         string
}

func darwinNakedSandboxCommand(opts darwinNakedSandboxCommandOptions) (string, []string, []string, error) {
	sandboxExecPath, err := lookPath("sandbox-exec")
	if err != nil {
		return "", nil, nil, fmt.Errorf("sandbox-exec is required for --naked on macOS")
	}
	profile := darwinNakedSandboxProfile(darwinNakedSandboxProfileOptions{
		workspace:       opts.workspace,
		extraReadPaths:  opts.extraReadPaths,
		extraWritePaths: opts.extraWritePaths,
		networkEnabled:  opts.networkEnabled,
	})
	env := nakedWorkspaceEnv(opts.workspace)
	if opts.openLog != "" {
		shim := filepath.Join(opts.workspace, configDir, "bin", "open")
		env = append(env,
			"BROWSER="+shim,
			"HERM_BROWSER_OPEN_LOG="+opts.openLog,
			"PATH="+filepath.Join(opts.workspace, configDir, "bin")+string(os.PathListSeparator)+os.Getenv("PATH"),
		)
	}
	return sandboxExecPath, []string{"-p", profile, "/bin/bash", "-lc", opts.command}, env, nil
}

type darwinNakedSandboxProfileOptions struct {
	workspace       string
	extraReadPaths  []string
	extraWritePaths []string
	networkEnabled  bool
}

func darwinNakedSandboxProfile(opts darwinNakedSandboxProfileOptions) string {
	quoted := sandboxProfileQuote(opts.workspace)
	var b strings.Builder
	for _, path := range normalizeNakedExternalPaths(normalizeNakedExternalPathsOptions{workspace: opts.workspace, paths: opts.extraReadPaths}) {
		q := sandboxProfileQuote(path)
		fmt.Fprintf(&b, "(allow file-read* (subpath %s))\n", q)
	}
	for _, path := range normalizeNakedExternalPaths(normalizeNakedExternalPathsOptions{workspace: opts.workspace, paths: opts.extraWritePaths}) {
		q := sandboxProfileQuote(path)
		fmt.Fprintf(&b, "(allow file-read* (subpath %s))\n", q)
		fmt.Fprintf(&b, "(allow file-write* (subpath %s))\n", q)
	}
	networkPolicy := ""
	if opts.networkEnabled {
		networkPolicy = "(allow network*)\n"
	}
	return fmt.Sprintf(`(version 1)
(deny default)
(allow process*)
(allow signal)
(allow sysctl-read)
(allow mach-lookup)
(allow user-preference-read)
(allow distributed-notification-post)
(allow appleevent-send)
(allow lsopen)
%s
(allow file-read*)
(allow file-write* (subpath %s))
%s`, networkPolicy, quoted, b.String())
}

const darwinBrowserOpenShim = `#!/bin/sh
if [ -z "$HERM_BROWSER_OPEN_LOG" ]; then
  exit 1
fi
{
  printf '__HERM_OPEN__\n'
  for arg in "$@"; do
    printf '%s\n' "$arg"
  done
  printf '__HERM_DONE__\n'
} >> "$HERM_BROWSER_OPEN_LOG"
exit 0
`

func writeDarwinBrowserOpenShim(workspace string) error {
	shimPath := filepath.Join(workspace, configDir, "bin", "open")
	if err := os.MkdirAll(filepath.Dir(shimPath), 0o755); err != nil {
		return fmt.Errorf("creating browser-open shim dir: %w", err)
	}
	if err := os.WriteFile(shimPath, []byte(darwinBrowserOpenShim), 0o755); err != nil {
		return fmt.Errorf("writing browser-open shim: %w", err)
	}
	return nil
}

type darwinBrowserOpenBroker struct {
	logPath string
	done    chan struct{}
	stopped chan struct{}
	mu      sync.Mutex
	errs    []string
	seen    int
	stop    sync.Once
}

func startDarwinBrowserOpenBroker(logPath string) *darwinBrowserOpenBroker {
	b := &darwinBrowserOpenBroker{
		logPath: logPath,
		done:    make(chan struct{}),
		stopped: make(chan struct{}),
	}
	go b.run()
	return b
}

func (b *darwinBrowserOpenBroker) run() {
	defer close(b.stopped)
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			b.process()
		case <-b.done:
			b.process()
			return
		}
	}
}

func (b *darwinBrowserOpenBroker) Stop() {
	if b == nil {
		return
	}
	b.stop.Do(func() {
		close(b.done)
		<-b.stopped
	})
}

func (b *darwinBrowserOpenBroker) Errors() string {
	if b == nil {
		return ""
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	if len(b.errs) == 0 {
		return ""
	}
	return strings.Join(b.errs, "\n") + "\n"
}

func (b *darwinBrowserOpenBroker) process() {
	records, err := readDarwinBrowserOpenRecords(b.logPath)
	if err != nil {
		if os.IsNotExist(err) {
			return
		}
		b.recordError(fmt.Sprintf("browser open broker: %v", err))
		return
	}
	for b.seen < len(records) {
		args := records[b.seen]
		b.seen++
		if len(args) == 0 {
			continue
		}
		if !darwinBrowserOpenArgsAllowed(args) {
			b.recordError("browser open broker: ignored non-URL open request")
			continue
		}
		if err := runDarwinOpen(args); err != nil {
			b.recordError(fmt.Sprintf("browser open broker: %v", err))
		}
	}
}

func darwinBrowserOpenArgsAllowed(args []string) bool {
	for _, arg := range args {
		lower := strings.ToLower(strings.TrimSpace(arg))
		if strings.HasPrefix(lower, "http://") || strings.HasPrefix(lower, "https://") {
			return true
		}
	}
	return false
}

func (b *darwinBrowserOpenBroker) recordError(msg string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.errs = append(b.errs, msg)
}

func readDarwinBrowserOpenRecords(path string) ([][]string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	lines := strings.Split(strings.ReplaceAll(string(data), "\r", ""), "\n")
	var records [][]string
	var current []string
	inRecord := false
	for _, line := range lines {
		switch line {
		case "__HERM_OPEN__":
			inRecord = true
			current = nil
		case "__HERM_DONE__":
			if inRecord {
				records = append(records, append([]string(nil), current...))
			}
			inRecord = false
			current = nil
		default:
			if inRecord {
				current = append(current, line)
			}
		}
	}
	return records, nil
}

var darwinOpenCommand = func(ctx context.Context, args []string) error {
	cmd := exec.CommandContext(ctx, "/usr/bin/open", args...)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		if msg := strings.TrimSpace(stderr.String()); msg != "" {
			return fmt.Errorf("%w: %s", err, msg)
		}
		return err
	}
	return nil
}

func runDarwinOpen(args []string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	return darwinOpenCommand(ctx, args)
}

func sandboxProfileQuote(s string) string {
	escaped := strings.ReplaceAll(s, `\`, `\\`)
	escaped = strings.ReplaceAll(escaped, `"`, `\"`)
	return `"` + escaped + `"`
}
