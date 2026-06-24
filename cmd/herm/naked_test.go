package main

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
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

func TestApprovedCommandStoreRecordsSegments(t *testing.T) {
	path := filepath.Join(t.TempDir(), ".herm", approvedCommandsFile)
	store := newApprovedCommandStore(path)
	command := "git status && go test ./cmd/herm"

	if !store.RequiresApproval(command) {
		t.Fatal("new command should require approval")
	}
	if err := store.RecordApproval(command); err != nil {
		t.Fatalf("RecordApproval: %v", err)
	}
	if store.RequiresApproval(command) {
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
	var file approvedCommandFile
	if err := json.Unmarshal(data, &file); err != nil {
		t.Fatalf("approval file JSON: %v", err)
	}
	if file.Version != 1 {
		t.Fatalf("version = %d, want 1", file.Version)
	}
	if !slices.Contains(file.Commands, "git status") || !slices.Contains(file.Commands, "go test ./cmd/herm") {
		t.Fatalf("commands = %#v, want recorded segments", file.Commands)
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

func TestNakedBashToolApprovalPolicyRecordsOnExecute(t *testing.T) {
	path := filepath.Join(t.TempDir(), ".herm", approvedCommandsFile)
	store := newApprovedCommandStore(path)
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
	if tool.RequiresApproval(input) {
		t.Fatal("executed command should have been recorded as approved")
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
	name, args, env, err := nakedSandboxCommand(nakedSandboxCommandOptions{
		goos:      "linux",
		workspace: workspace,
		command:   "go test ./...",
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
	name, args, env, err := nakedSandboxCommand(nakedSandboxCommandOptions{
		goos:      "darwin",
		workspace: workspace,
		command:   "go test ./...",
	})
	if err != nil {
		t.Fatalf("nakedSandboxCommand: %v", err)
	}
	if name != "/usr/bin/sandbox-exec" {
		t.Fatalf("name = %q, want /usr/bin/sandbox-exec", name)
	}
	if len(args) < 5 || args[0] != "-p" || args[len(args)-3] != "bash" || args[len(args)-2] != "-lc" || args[len(args)-1] != "go test ./..." {
		t.Fatalf("sandbox-exec args = %#v", args)
	}
	if !strings.Contains(args[1], `(allow file-write* (subpath "`+workspace+`"))`) {
		t.Fatalf("profile = %q, want workspace write allowance", args[1])
	}
	if !slices.Contains(env, "HOME="+filepath.Join(workspace, configDir, "home")) {
		t.Fatalf("env = %#v, want HOME in workspace", env)
	}
}
