package main

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"testing"
)

func TestCommandApprovalSegmentsSplitShellOperators(t *testing.T) {
	got := commandApprovalSegments(`git status && go test ./... | tee out.txt; echo "a && b"`)
	want := []string{"git status", "go test ./...", "tee out.txt", `echo "a && b"`}
	if !slices.Equal(got, want) {
		t.Fatalf("segments = %#v, want %#v", got, want)
	}
}

func TestNakedPermissionStoreRecordsCommandsAndExternalPaths(t *testing.T) {
	workspace := t.TempDir()
	outsideDir := t.TempDir()
	outsidePath := filepath.Join(outsideDir, "config.json")
	if err := os.WriteFile(outsidePath, []byte("{}"), 0o644); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(workspace, ".herm", nakedPermissionsFile)
	store := newNakedPermissionStore(path, workspace)
	command := "git status && go test ./cmd/herm"
	commandWithPath := command + " --config " + outsidePath

	if !store.RequiresApproval(commandWithPath) {
		t.Fatal("new command should require approval")
	}
	if err := store.RecordApproval(commandWithPath, true); err != nil {
		t.Fatalf("RecordApproval: %v", err)
	}
	if store.RequiresApproval(commandWithPath) {
		t.Fatal("recorded command should not require approval")
	}
	if store.RequiresApproval("git status") {
		t.Fatal("recorded segment should not require approval")
	}
	if !store.RequiresApproval("git diff") {
		t.Fatal("unrecorded command should require approval")
	}

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read approval file: %v", err)
	}
	var file nakedPermissionFile
	if err := json.Unmarshal(data, &file); err != nil {
		t.Fatalf("approval file JSON: %v", err)
	}
	if file.Version != 1 {
		t.Fatalf("version = %d, want 1", file.Version)
	}
	if !slices.Contains(file.Commands, "git status") || !slices.Contains(file.Commands, "go test ./cmd/herm --config "+outsidePath) {
		t.Fatalf("commands = %#v, want recorded segments", file.Commands)
	}
	if !slices.Contains(file.Paths, outsidePath) {
		t.Fatalf("paths = %#v, want %q", file.Paths, outsidePath)
	}
}

func TestNakedPermissionStoreRegexesAreUserEditableAndNotRecorded(t *testing.T) {
	workspace := t.TempDir()
	outsideDir := t.TempDir()
	outsidePath := filepath.Join(outsideDir, "token.txt")
	if err := os.WriteFile(outsidePath, []byte("secret"), 0o644); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(workspace, ".herm", nakedPermissionsFile)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	file := nakedPermissionFile{
		Version:        1,
		CommandRegexes: []string{`^git status\b`},
		PathRegexes:    []string{`^` + regexp.QuoteMeta(outsideDir) + `/.*\.txt$`},
	}
	data, err := json.Marshal(file)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatal(err)
	}
	store := newNakedPermissionStore(path, workspace)

	if store.RequiresApproval("git status --short " + outsidePath) {
		t.Fatal("regex-approved command and path should not require approval")
	}
	if !store.RequiresApproval("git diff " + outsidePath) {
		t.Fatal("unmatched command should require approval")
	}
}

func TestNakedPermissionStoreAcceptOnceDoesNotPersist(t *testing.T) {
	workspace := t.TempDir()
	path := filepath.Join(workspace, ".herm", nakedPermissionsFile)
	store := newNakedPermissionStore(path, workspace)
	command := "git status"

	if err := store.RecordApproval(command, false); err != nil {
		t.Fatalf("RecordApproval: %v", err)
	}
	if store.RequiresApproval(command) {
		t.Fatal("one-shot approval should allow the pending command")
	}
	store.FinishApproval(command)
	if !store.RequiresApproval(command) {
		t.Fatal("one-shot approval should be cleared after execution")
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("one-shot approval wrote permissions file: %v", err)
	}
}

func TestCommandExternalPathsIncludesRelativeOutsideWorkspace(t *testing.T) {
	root := t.TempDir()
	workspace := filepath.Join(root, "project")
	if err := os.MkdirAll(workspace, 0o755); err != nil {
		t.Fatal(err)
	}
	got := commandExternalPaths("cat ../secrets.env", workspace)
	want := filepath.Join(root, "secrets.env")
	if !slices.Equal(got, []string{want}) {
		t.Fatalf("external paths = %#v, want %#v", got, []string{want})
	}
}

type fakeBashRunner struct {
	command string
	result  CommandResult
}

func (r *fakeBashRunner) RunBash(_ context.Context, opts bashRunOptions) (CommandResult, error) {
	r.command = opts.command
	return r.result, nil
}

func TestNakedBashToolApprovalPolicyRecordsOnlyWhenRequested(t *testing.T) {
	workspace := t.TempDir()
	path := filepath.Join(workspace, ".herm", nakedPermissionsFile)
	store := newNakedPermissionStore(path, workspace)
	runner := &fakeBashRunner{result: CommandResult{Stdout: "ok\n"}}
	tool := &BashTool{
		name:                toolBash,
		runner:              runner,
		timeout:             120,
		descriptionFallback: "fallback",
		approvalPolicy:      store,
		hostTool:            true,
	}
	input := json.RawMessage(`{"command":"echo a &amp;&amp; echo b"}`)

	if !tool.RequiresApproval(input) {
		t.Fatal("new naked bash command should require approval")
	}
	if err := tool.RecordApproval(input, false); err != nil {
		t.Fatalf("RecordApproval once: %v", err)
	}
	out, err := tool.Execute(context.Background(), input)
	if err != nil {
		t.Fatalf("Execute: %v", err)
	}
	if out != "ok\n" {
		t.Fatalf("output = %q, want ok", out)
	}
	if runner.command != "echo a && echo b" {
		t.Fatalf("runner command = %q, want HTML-unescaped command", runner.command)
	}
	if !tool.RequiresApproval(input) {
		t.Fatal("accept-once command should require approval again after execution")
	}
	if err := tool.RecordApproval(input, true); err != nil {
		t.Fatalf("RecordApproval always: %v", err)
	}
	if tool.RequiresApproval(input) {
		t.Fatal("always-approved command should not require approval")
	}
}

func TestLinuxNakedSandboxCommandUsesBubblewrapWorkspaceBind(t *testing.T) {
	origLookPath := lookPath
	t.Cleanup(func() { lookPath = origLookPath })
	lookPath = func(file string) (string, error) {
		if file == "bwrap" {
			return "/usr/bin/bwrap", nil
		}
		return "", errors.New("not found")
	}

	workspace := filepath.Join(t.TempDir(), "project")
	if err := os.MkdirAll(workspace, 0o755); err != nil {
		t.Fatal(err)
	}
	outsideFile := filepath.Join(t.TempDir(), "token.txt")
	if err := os.WriteFile(outsideFile, []byte("secret"), 0o600); err != nil {
		t.Fatal(err)
	}
	name, args, env, err := nakedSandboxCommand(nakedSandboxCommandOptions{
		goos:       "linux",
		workspace:  workspace,
		command:    "go test ./...",
		extraPaths: []string{outsideFile},
	})
	if err != nil {
		t.Fatalf("nakedSandboxCommand: %v", err)
	}
	if name != "/usr/bin/bwrap" {
		t.Fatalf("name = %q, want /usr/bin/bwrap", name)
	}
	if len(env) != 0 {
		t.Fatalf("env = %#v, want none for bubblewrap command", env)
	}
	joined := "\x00" + strings.Join(args, "\x00") + "\x00"
	for _, want := range []string{
		"\x00--unshare-all\x00",
		"\x00--share-net\x00",
		"\x00--bind\x00" + workspace + "\x00" + workspace + "\x00",
		"\x00--bind\x00" + outsideFile + "\x00" + outsideFile + "\x00",
		"\x00--chdir\x00" + workspace + "\x00",
		"\x00bash\x00-lc\x00go test ./...\x00",
	} {
		if !strings.Contains(joined, want) {
			t.Fatalf("bubblewrap args missing %q in %#v", want, args)
		}
	}
}

func TestDarwinNakedSandboxCommandUsesWorkspaceWriteProfile(t *testing.T) {
	origLookPath := lookPath
	t.Cleanup(func() { lookPath = origLookPath })
	lookPath = func(file string) (string, error) {
		if file == "sandbox-exec" {
			return "/usr/bin/sandbox-exec", nil
		}
		return "", errors.New("not found")
	}

	workspace := filepath.Join(t.TempDir(), "project")
	outsideFile := filepath.Join(t.TempDir(), "token.txt")
	name, args, env, err := nakedSandboxCommand(nakedSandboxCommandOptions{
		goos:       "darwin",
		workspace:  workspace,
		command:    "go test ./...",
		extraPaths: []string{outsideFile},
	})
	if err != nil {
		t.Fatalf("nakedSandboxCommand: %v", err)
	}
	if name != "/usr/bin/sandbox-exec" {
		t.Fatalf("name = %q, want /usr/bin/sandbox-exec", name)
	}
	if len(args) < 5 || args[0] != "-p" || args[len(args)-3] != "/bin/bash" || args[len(args)-2] != "-lc" || args[len(args)-1] != "go test ./..." {
		t.Fatalf("sandbox-exec args = %#v", args)
	}
	if !strings.Contains(args[1], "(allow file-read*)") {
		t.Fatalf("profile = %q, want broad file reads for macOS command startup", args[1])
	}
	if !strings.Contains(args[1], `(allow file-write* (subpath "`+workspace+`"))`) {
		t.Fatalf("profile = %q, want workspace write allowance", args[1])
	}
	if !strings.Contains(args[1], `(allow file-read* (subpath "`+outsideFile+`"))`) || !strings.Contains(args[1], `(allow file-write* (subpath "`+outsideFile+`"))`) {
		t.Fatalf("profile = %q, want outside file allowance", args[1])
	}
	if !slices.Contains(env, "HOME="+filepath.Join(workspace, configDir, "home")) {
		t.Fatalf("env = %#v, want HOME in workspace", env)
	}
}
