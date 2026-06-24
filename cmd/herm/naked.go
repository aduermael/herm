package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strings"
	"sync"
	"time"
)

const nakedPermissionsFile = "permissions.json"

// sandboxCommand is a function variable for exec.CommandContext, replaceable in tests.
var sandboxCommand = exec.CommandContext

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

	var extraPaths []string
	if r.permissions != nil {
		extraPaths = r.permissions.AllowedExternalPaths(opts.command)
	}
	name, args, env, err := nakedSandboxCommand(nakedSandboxCommandOptions{
		goos:       runtime.GOOS,
		workspace:  workspace,
		command:    opts.command,
		extraPaths: extraPaths,
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
	goos       string
	workspace  string
	command    string
	extraPaths []string
}

func nakedSandboxCommand(opts nakedSandboxCommandOptions) (name string, args []string, env []string, err error) {
	switch opts.goos {
	case "linux":
		return linuxNakedSandboxCommand(opts.workspace, opts.command, opts.extraPaths)
	case "darwin":
		return darwinNakedSandboxCommand(opts.workspace, opts.command, opts.extraPaths)
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

func linuxNakedSandboxCommand(workspace, command string, extraPaths []string) (string, []string, []string, error) {
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
	for _, path := range normalizeNakedExternalPaths(workspace, extraPaths) {
		info, err := os.Stat(path)
		if err != nil {
			continue
		}
		parentPath := filepath.Dir(path)
		if info.IsDir() {
			parentPath = path
		}
		for _, dir := range sandboxParentDirs(parentPath) {
			args = append(args, "--dir", dir)
		}
		args = append(args, "--bind", path, path)
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

func darwinNakedSandboxCommand(workspace, command string, extraPaths []string) (string, []string, []string, error) {
	sandboxExecPath, err := lookPath("sandbox-exec")
	if err != nil {
		return "", nil, nil, fmt.Errorf("sandbox-exec is required for --naked on macOS")
	}
	profile := darwinNakedSandboxProfile(workspace, extraPaths)
	env := []string{
		"HOME=" + filepath.Join(workspace, configDir, "home"),
		"XDG_CACHE_HOME=" + filepath.Join(workspace, configDir, "cache"),
		"TMPDIR=" + filepath.Join(workspace, configDir, "tmp"),
	}
	return sandboxExecPath, []string{"-p", profile, "/bin/bash", "-lc", command}, env, nil
}

func darwinNakedSandboxProfile(workspace string, extraPaths []string) string {
	quoted := sandboxProfileQuote(workspace)
	var b strings.Builder
	for _, path := range normalizeNakedExternalPaths(workspace, extraPaths) {
		q := sandboxProfileQuote(path)
		fmt.Fprintf(&b, "(allow file-read* (subpath %s))\n", q)
		fmt.Fprintf(&b, "(allow file-write* (subpath %s))\n", q)
	}
	return fmt.Sprintf(`(version 1)
(deny default)
(allow process*)
(allow signal)
(allow sysctl-read)
(allow mach-lookup)
(allow network*)
(allow file-read*)
(allow file-write* (subpath %s))
%s`, quoted, b.String())
}

func sandboxProfileQuote(s string) string {
	escaped := strings.ReplaceAll(s, `\`, `\\`)
	escaped = strings.ReplaceAll(escaped, `"`, `\"`)
	return `"` + escaped + `"`
}

func nakedPermissionsPath(workspace string) string {
	return filepath.Join(workspace, configDir, nakedPermissionsFile)
}

type nakedPermissionStore struct {
	path      string
	workspace string
	mu        sync.Mutex
	once      nakedPermissionSet
}

func newNakedPermissionStore(path, workspace string) *nakedPermissionStore {
	if path == "" {
		return nil
	}
	workspace, _ = filepath.Abs(workspace)
	return &nakedPermissionStore{path: path, workspace: workspace}
}

type nakedPermissionFile struct {
	Version        int      `json:"version"`
	Commands       []string `json:"commands"`
	CommandRegexes []string `json:"command_regexes,omitempty"`
	Paths          []string `json:"paths,omitempty"`
	PathRegexes    []string `json:"path_regexes,omitempty"`
}

type nakedPermissionSet struct {
	Commands map[string]bool
	Paths    map[string]bool
}

type loadedNakedPermissions struct {
	file            nakedPermissionFile
	commands        map[string]bool
	commandRegexes  []*regexp.Regexp
	paths           map[string]bool
	pathRegexes     []*regexp.Regexp
	invalidRegexes  []string
	invalidPatterns []string
}

func (s *nakedPermissionStore) RequiresApproval(command string) bool {
	if s == nil || strings.TrimSpace(command) == "" {
		return false
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	permissions, err := s.loadLocked()
	if err != nil {
		return true
	}
	for _, segment := range commandApprovalSegments(command) {
		if !s.commandAllowedLocked(permissions, segment) {
			return true
		}
	}
	for _, path := range commandExternalPaths(command, s.workspace) {
		if !s.pathAllowedLocked(permissions, path) {
			return true
		}
	}
	return false
}

func (s *nakedPermissionStore) RecordApproval(command string, remember bool) error {
	if s == nil || strings.TrimSpace(command) == "" {
		return nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	if remember {
		permissions, err := s.loadLocked()
		if err != nil {
			return err
		}
		changed := false
		for _, segment := range commandApprovalSegments(command) {
			if segment != "" && !permissions.commands[segment] {
				permissions.commands[segment] = true
				changed = true
			}
		}
		for _, path := range commandExternalPaths(command, s.workspace) {
			if path != "" && !permissions.paths[path] {
				permissions.paths[path] = true
				changed = true
			}
		}
		if !changed {
			return nil
		}
		return s.saveLocked(permissions)
	}

	for _, segment := range commandApprovalSegments(command) {
		if segment != "" {
			if s.once.Commands == nil {
				s.once.Commands = map[string]bool{}
			}
			s.once.Commands[segment] = true
		}
	}
	for _, path := range commandExternalPaths(command, s.workspace) {
		if path != "" {
			if s.once.Paths == nil {
				s.once.Paths = map[string]bool{}
			}
			s.once.Paths[path] = true
		}
	}
	return nil
}

func (s *nakedPermissionStore) FinishApproval(command string) {
	if s == nil || strings.TrimSpace(command) == "" {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, segment := range commandApprovalSegments(command) {
		delete(s.once.Commands, segment)
	}
	for _, path := range commandExternalPaths(command, s.workspace) {
		delete(s.once.Paths, path)
	}
}

func (s *nakedPermissionStore) AllowedExternalPaths(command string) []string {
	if s == nil || strings.TrimSpace(command) == "" {
		return nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	permissions, err := s.loadLocked()
	if err != nil {
		return nil
	}
	var paths []string
	for _, path := range commandExternalPaths(command, s.workspace) {
		if s.pathAllowedLocked(permissions, path) {
			paths = append(paths, path)
		}
	}
	return uniqueSortedStrings(paths)
}

func (s *nakedPermissionStore) commandAllowedLocked(permissions loadedNakedPermissions, command string) bool {
	if permissions.commands[command] || s.once.Commands[command] {
		return true
	}
	for _, re := range permissions.commandRegexes {
		if re.MatchString(command) {
			return true
		}
	}
	return false
}

func (s *nakedPermissionStore) pathAllowedLocked(permissions loadedNakedPermissions, path string) bool {
	if permissions.paths[path] || s.once.Paths[path] {
		return true
	}
	for _, re := range permissions.pathRegexes {
		if re.MatchString(path) {
			return true
		}
	}
	return false
}

func (s *nakedPermissionStore) loadLocked() (loadedNakedPermissions, error) {
	loaded := loadedNakedPermissions{
		file: nakedPermissionFile{
			Version: 1,
		},
		commands: map[string]bool{},
		paths:    map[string]bool{},
	}
	data, err := os.ReadFile(s.path)
	if os.IsNotExist(err) {
		return loaded, nil
	}
	if err != nil {
		return loaded, err
	}
	if err := json.Unmarshal(data, &loaded.file); err != nil {
		return loaded, err
	}
	for _, command := range loaded.file.Commands {
		command = strings.TrimSpace(command)
		if command != "" {
			loaded.commands[command] = true
		}
	}
	for _, path := range loaded.file.Paths {
		if normalized, ok := normalizeNakedPath(s.workspace, path); ok {
			loaded.paths[normalized] = true
		}
	}
	loaded.commandRegexes, loaded.invalidRegexes = compileNakedRegexes(loaded.file.CommandRegexes)
	loaded.pathRegexes, loaded.invalidPatterns = compileNakedRegexes(loaded.file.PathRegexes)
	return loaded, nil
}

func (s *nakedPermissionStore) saveLocked(permissions loadedNakedPermissions) error {
	commands := make([]string, 0, len(permissions.commands))
	for command := range permissions.commands {
		commands = append(commands, command)
	}
	sort.Strings(commands)

	paths := make([]string, 0, len(permissions.paths))
	for path := range permissions.paths {
		paths = append(paths, path)
	}
	sort.Strings(paths)

	file := permissions.file
	file.Version = 1
	file.Commands = commands
	file.Paths = paths
	data, err := json.MarshalIndent(file, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(s.path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(s.path, append(data, '\n'), 0o644)
}

func compileNakedRegexes(patterns []string) ([]*regexp.Regexp, []string) {
	var regexes []*regexp.Regexp
	var invalid []string
	for _, pattern := range patterns {
		pattern = strings.TrimSpace(pattern)
		if pattern == "" {
			continue
		}
		re, err := regexp.Compile(pattern)
		if err != nil {
			invalid = append(invalid, pattern)
			continue
		}
		regexes = append(regexes, re)
	}
	return regexes, invalid
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

func commandExternalPaths(command, workspace string) []string {
	var paths []string
	for _, word := range shellWords(command) {
		for _, candidate := range pathCandidatesFromShellWord(word) {
			if normalized, ok := normalizeNakedPath(workspace, candidate); ok {
				paths = append(paths, normalized)
			}
		}
	}
	return uniqueSortedStrings(paths)
}

func pathCandidatesFromShellWord(word string) []string {
	if word == "" {
		return nil
	}
	word = strings.Trim(word, `"'`)
	word = strings.TrimRight(word, `,`)
	var candidates []string
	if isNakedPathCandidate(word) {
		candidates = append(candidates, word)
	}
	if idx := strings.IndexByte(word, '='); idx >= 0 && idx+1 < len(word) {
		value := strings.Trim(word[idx+1:], `"'`)
		if isNakedPathCandidate(value) {
			candidates = append(candidates, value)
		}
	}
	return candidates
}

func isNakedPathCandidate(s string) bool {
	return strings.HasPrefix(s, "/") || strings.HasPrefix(s, "~/") || strings.HasPrefix(s, "../")
}

func shellWords(command string) []string {
	var words []string
	var b strings.Builder
	var quote rune
	escaped := false
	flush := func() {
		if b.Len() == 0 {
			return
		}
		word := strings.TrimSpace(b.String())
		if word != "" {
			words = append(words, word)
		}
		b.Reset()
	}

	for _, r := range command {
		if escaped {
			b.WriteRune(r)
			escaped = false
			continue
		}
		if r == '\\' && quote != '\'' {
			escaped = true
			continue
		}
		if quote != 0 {
			if r == quote {
				quote = 0
				continue
			}
			b.WriteRune(r)
			continue
		}
		switch r {
		case '\'', '"':
			quote = r
		case ' ', '\t', '\n', ';', '|', '&', '(', ')':
			flush()
		default:
			b.WriteRune(r)
		}
	}
	flush()
	return words
}

func normalizeNakedPath(workspace, path string) (string, bool) {
	if strings.HasPrefix(path, "~/") {
		if home, err := os.UserHomeDir(); err == nil {
			path = filepath.Join(home, strings.TrimPrefix(path, "~/"))
		}
	}
	if !filepath.IsAbs(path) {
		if workspace == "" {
			return "", false
		}
		path = filepath.Join(workspace, path)
	}
	normalized := filepath.Clean(path)
	if resolved, err := filepath.EvalSymlinks(normalized); err == nil {
		normalized = resolved
	}
	workspace = filepath.Clean(workspace)
	if resolved, err := filepath.EvalSymlinks(workspace); err == nil {
		workspace = resolved
	}
	if normalized == workspace || strings.HasPrefix(normalized, workspace+string(filepath.Separator)) {
		return "", false
	}
	return normalized, true
}

func normalizeNakedExternalPaths(workspace string, paths []string) []string {
	var normalized []string
	for _, path := range paths {
		if p, ok := normalizeNakedPath(workspace, path); ok {
			normalized = append(normalized, p)
		}
	}
	return uniqueSortedStrings(normalized)
}

func uniqueSortedStrings(values []string) []string {
	if len(values) == 0 {
		return nil
	}
	seen := make(map[string]bool, len(values))
	var out []string
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value == "" || seen[value] {
			continue
		}
		seen[value] = true
		out = append(out, value)
	}
	sort.Strings(out)
	return out
}
