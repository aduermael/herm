package main

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
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

func TestCommandApprovalSegmentsSplitSubshellBoundaries(t *testing.T) {
	got := commandApprovalSegments(`echo $(cat /tmp/token) & (pwd; ls)`)
	want := []string{"echo", "cat /tmp/token", "pwd", "ls"}
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
	store := newNakedPermissionStore(newNakedPermissionStoreOptions{path: path, workspace: workspace})
	command := "git status && go test ./cmd/herm"
	commandWithPath := command + " --config " + outsidePath

	if !store.RequiresApproval(commandWithPath) {
		t.Fatal("new command should require approval")
	}
	if err := store.RecordApproval(recordCommandApprovalOptions{command: commandWithPath, remember: true}); err != nil {
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
	store := newNakedPermissionStore(newNakedPermissionStoreOptions{path: path, workspace: workspace})

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
	store := newNakedPermissionStore(newNakedPermissionStoreOptions{path: path, workspace: workspace})
	command := "git status"

	if err := store.RecordApproval(recordCommandApprovalOptions{command: command, remember: false}); err != nil {
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

func TestNakedPermissionStoreRecordsCommandPrefixes(t *testing.T) {
	workspace := t.TempDir()
	path := filepath.Join(workspace, ".herm", nakedPermissionsFile)
	store := newNakedPermissionStore(newNakedPermissionStoreOptions{path: path, workspace: workspace})
	command := "npm run build -- --watch"

	if err := store.RecordApproval(recordCommandApprovalOptions{
		command:         command,
		commandPrefixes: [][]string{{"npm", "run"}},
		remember:        true,
	}); err != nil {
		t.Fatalf("RecordApproval: %v", err)
	}
	if store.RequiresApproval("npm run test") {
		t.Fatal("recorded prefix should approve matching command")
	}
	if !store.RequiresApproval("npm install") {
		t.Fatal("different npm prefix should still require approval")
	}

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read approval file: %v", err)
	}
	var file nakedPermissionFile
	if err := json.Unmarshal(data, &file); err != nil {
		t.Fatalf("approval file JSON: %v", err)
	}
	if len(file.CommandPrefixes) != 1 || !slices.Equal(file.CommandPrefixes[0], []string{"npm", "run"}) {
		t.Fatalf("command_prefixes = %#v, want npm run prefix", file.CommandPrefixes)
	}
}

func TestNakedPermissionStoreRecordsRequestedPermissions(t *testing.T) {
	workspace := t.TempDir()
	outsideDir := t.TempDir()
	readPath := filepath.Join(outsideDir, "read.txt")
	writePath := filepath.Join(outsideDir, "write.txt")
	path := filepath.Join(workspace, ".herm", nakedPermissionsFile)
	store := newNakedPermissionStore(newNakedPermissionStoreOptions{path: path, workspace: workspace})
	permissions := bashAdditionalPermissions{
		Network: bashNetworkPermissions{Enabled: true},
		FileSystem: bashFileSystemPermissions{
			Read:  []string{readPath},
			Write: []string{writePath},
		},
	}

	if !store.RequestedPermissionsRequireApproval(permissions) {
		t.Fatal("new requested permissions should require approval")
	}
	if err := store.RecordRequestedPermissions(recordRequestedPermissionsOptions{permissions: permissions, remember: false}); err != nil {
		t.Fatalf("RecordRequestedPermissions once: %v", err)
	}
	if store.RequestedPermissionsRequireApproval(permissions) {
		t.Fatal("one-shot requested permissions should be approved")
	}
	readPaths, writePaths, network := store.RequestedSandboxPermissions()
	if !network || !slices.Equal(readPaths, []string{readPath}) || !slices.Equal(writePaths, []string{writePath}) {
		t.Fatalf("requested sandbox permissions = read %#v write %#v network %v", readPaths, writePaths, network)
	}
	store.FinishRequestedPermissionsOnce()
	if !store.RequestedPermissionsRequireApproval(permissions) {
		t.Fatal("one-shot requested permissions should clear after consumption")
	}

	if err := store.RecordRequestedPermissions(recordRequestedPermissionsOptions{permissions: permissions, remember: true}); err != nil {
		t.Fatalf("RecordRequestedPermissions remembered: %v", err)
	}
	if store.RequestedPermissionsRequireApproval(permissions) {
		t.Fatal("remembered requested permissions should be approved")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read approval file: %v", err)
	}
	var file nakedPermissionFile
	if err := json.Unmarshal(data, &file); err != nil {
		t.Fatalf("approval file JSON: %v", err)
	}
	if !file.Network || !slices.Equal(file.ReadPaths, []string{readPath}) || !slices.Equal(file.WritePaths, []string{writePath}) {
		t.Fatalf("approval file = %#v, want requested permissions persisted", file)
	}
}

func TestCommandExternalPathsIncludesRelativeOutsideWorkspace(t *testing.T) {
	root := t.TempDir()
	workspace := filepath.Join(root, "project")
	if err := os.MkdirAll(workspace, 0o755); err != nil {
		t.Fatal(err)
	}
	got := commandExternalPaths(commandExternalPathsOptions{command: "cat ../secrets.env", workspace: workspace})
	want := filepath.Join(root, "secrets.env")
	if !slices.Equal(got, []string{want}) {
		t.Fatalf("external paths = %#v, want %#v", got, []string{want})
	}
}

type fakeBashRunner struct {
	command               string
	sandboxPermissions    string
	additionalPermissions bashAdditionalPermissions
	result                CommandResult
}

func (r *fakeBashRunner) RunBash(_ context.Context, opts bashRunOptions) (CommandResult, error) {
	r.command = opts.command
	r.sandboxPermissions = opts.sandboxPermissions
	r.additionalPermissions = opts.additionalPermissions
	return r.result, nil
}

func TestNakedBashToolApprovalPolicyRecordsOnlyWhenRequested(t *testing.T) {
	workspace := t.TempDir()
	path := filepath.Join(workspace, ".herm", nakedPermissionsFile)
	store := newNakedPermissionStore(newNakedPermissionStoreOptions{path: path, workspace: workspace})
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
	if err := tool.RecordApproval(recordToolApprovalOptions{input: input, remember: false}); err != nil {
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
	if runner.sandboxPermissions != bashSandboxPermissionsUseDefault {
		t.Fatalf("runner sandboxPermissions = %q, want use_default", runner.sandboxPermissions)
	}
	if !tool.RequiresApproval(input) {
		t.Fatal("accept-once command should require approval again after execution")
	}
	if err := tool.RecordApproval(recordToolApprovalOptions{input: input, remember: true}); err != nil {
		t.Fatalf("RecordApproval always: %v", err)
	}
	if tool.RequiresApproval(input) {
		t.Fatal("always-approved command should not require approval")
	}
}

func TestNakedBashToolRequireEscalatedUsesSeparateApproval(t *testing.T) {
	workspace := t.TempDir()
	outsideFile := filepath.Join(t.TempDir(), "token.txt")
	if err := os.WriteFile(outsideFile, []byte("secret"), 0o600); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(workspace, ".herm", nakedPermissionsFile)
	store := newNakedPermissionStore(newNakedPermissionStoreOptions{path: path, workspace: workspace})
	runner := &fakeBashRunner{result: CommandResult{Stdout: "ok\n"}}
	tool := &BashTool{
		name:                toolBash,
		runner:              runner,
		timeout:             120,
		descriptionFallback: "fallback",
		approvalPolicy:      store,
		hostTool:            true,
	}
	defaultInput := json.RawMessage(`{"command":"cat ` + outsideFile + `"}`)
	escalatedInput := json.RawMessage(`{"command":"cat ` + outsideFile + `","sandbox_permissions":"require_escalated","justification":"Allow reading this file outside the sandbox?"}`)

	if err := tool.RecordApproval(recordToolApprovalOptions{input: defaultInput, remember: true}); err != nil {
		t.Fatalf("RecordApproval default: %v", err)
	}
	if tool.RequiresApproval(defaultInput) {
		t.Fatal("sandboxed command should be approved")
	}
	if !tool.RequiresApproval(escalatedInput) {
		t.Fatal("sandboxed approval must not authorize escalated execution")
	}
	if err := tool.RecordApproval(recordToolApprovalOptions{input: escalatedInput, remember: false}); err != nil {
		t.Fatalf("RecordApproval escalated once: %v", err)
	}
	out, err := tool.Execute(context.Background(), escalatedInput)
	if err != nil {
		t.Fatalf("Execute escalated: %v", err)
	}
	if out != "ok\n" {
		t.Fatalf("output = %q, want ok", out)
	}
	if runner.sandboxPermissions != bashSandboxPermissionsRequireEscalated {
		t.Fatalf("runner sandboxPermissions = %q, want require_escalated", runner.sandboxPermissions)
	}
	if !tool.RequiresApproval(escalatedInput) {
		t.Fatal("one-shot escalated approval should be cleared after execution")
	}
}

func TestNakedBashToolWithAdditionalPermissionsUsesSeparateApproval(t *testing.T) {
	workspace := t.TempDir()
	outsideFile := filepath.Join(t.TempDir(), "token.txt")
	if err := os.WriteFile(outsideFile, []byte("secret"), 0o600); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(workspace, ".herm", nakedPermissionsFile)
	store := newNakedPermissionStore(newNakedPermissionStoreOptions{path: path, workspace: workspace})
	runner := &fakeBashRunner{result: CommandResult{Stdout: "ok\n"}}
	tool := &BashTool{
		name:                toolBash,
		runner:              runner,
		timeout:             120,
		descriptionFallback: "fallback",
		approvalPolicy:      store,
		hostTool:            true,
	}
	defaultInput := json.RawMessage(`{"command":"cat ` + outsideFile + `"}`)
	additionalInput := json.RawMessage(`{"command":"cat ` + outsideFile + `","sandbox_permissions":"with_additional_permissions","additional_permissions":{"file_system":{"read":["` + outsideFile + `"]}}}`)

	if err := tool.RecordApproval(recordToolApprovalOptions{input: defaultInput, remember: true}); err != nil {
		t.Fatalf("RecordApproval default: %v", err)
	}
	if !tool.RequiresApproval(additionalInput) {
		t.Fatal("sandboxed approval must not authorize additional-permission execution")
	}
	if err := tool.RecordApproval(recordToolApprovalOptions{input: additionalInput, remember: false}); err != nil {
		t.Fatalf("RecordApproval additional once: %v", err)
	}
	out, err := tool.Execute(context.Background(), additionalInput)
	if err != nil {
		t.Fatalf("Execute additional permissions: %v", err)
	}
	if out != "ok\n" {
		t.Fatalf("output = %q, want ok", out)
	}
	if runner.sandboxPermissions != bashSandboxPermissionsWithAdditional {
		t.Fatalf("runner sandboxPermissions = %q, want with_additional_permissions", runner.sandboxPermissions)
	}
	if !slices.Equal(runner.additionalPermissions.FileSystem.Read, []string{outsideFile}) {
		t.Fatalf("runner additional read paths = %#v, want %q", runner.additionalPermissions.FileSystem.Read, outsideFile)
	}
	if !tool.RequiresApproval(additionalInput) {
		t.Fatal("one-shot additional-permission approval should be cleared after execution")
	}
}

func TestNakedBashToolPrefixRuleIsScopedToSandboxPermissions(t *testing.T) {
	workspace := t.TempDir()
	path := filepath.Join(workspace, ".herm", nakedPermissionsFile)
	store := newNakedPermissionStore(newNakedPermissionStoreOptions{path: path, workspace: workspace})
	runner := &fakeBashRunner{result: CommandResult{Stdout: "ok\n"}}
	tool := &BashTool{
		name:                toolBash,
		runner:              runner,
		timeout:             120,
		descriptionFallback: "fallback",
		approvalPolicy:      store,
		hostTool:            true,
	}
	input := json.RawMessage(`{"command":"npm run build","sandbox_permissions":"require_escalated","prefix_rule":["npm","run"],"justification":"Allow npm scripts outside the sandbox?"}`)

	if err := tool.RecordApproval(recordToolApprovalOptions{input: input, remember: true}); err != nil {
		t.Fatalf("RecordApproval prefix: %v", err)
	}
	escalatedNext := json.RawMessage(`{"command":"npm run test","sandbox_permissions":"require_escalated","justification":"Allow npm scripts outside the sandbox?"}`)
	if tool.RequiresApproval(escalatedNext) {
		t.Fatal("escalated prefix should approve matching escalated command")
	}
	defaultNext := json.RawMessage(`{"command":"npm run test"}`)
	if !tool.RequiresApproval(defaultNext) {
		t.Fatal("escalated prefix must not approve default sandbox command")
	}
}

func TestBashApprovalCommandScopesEverySegment(t *testing.T) {
	got := commandApprovalSegments(bashApprovalCommand(bashApprovalCommandOptions{
		command:               "cat /tmp/a && echo ok",
		sandboxPermissions:    bashSandboxPermissionsRequireEscalated,
		additionalPermissions: bashAdditionalPermissions{},
	}))
	want := []string{"require_escalated: cat /tmp/a", "require_escalated: echo ok"}
	if !slices.Equal(got, want) {
		t.Fatalf("approval segments = %#v, want %#v", got, want)
	}

	permissions := bashAdditionalPermissions{
		Network: bashNetworkPermissions{Enabled: true},
		FileSystem: bashFileSystemPermissions{
			Read: []string{"/tmp/read.txt"},
		},
	}
	key := bashApprovalCommand(bashApprovalCommandOptions{
		command:               "cat data",
		sandboxPermissions:    bashSandboxPermissionsWithAdditional,
		additionalPermissions: permissions,
	})
	if !strings.Contains(key, `with_additional_permissions: network.enabled=true __herm_read="/tmp/read.txt" cat data`) ||
		!strings.Contains(key, "network.enabled=true") ||
		!strings.Contains(key, `__herm_read="/tmp/read.txt"`) {
		t.Fatalf("additional-permission approval key = %q", key)
	}
	prefixRules := bashApprovalPrefixRules(bashApprovalPrefixRulesOptions{
		prefixRule:            []string{"cat"},
		sandboxPermissions:    bashSandboxPermissionsWithAdditional,
		additionalPermissions: permissions,
	})
	wantRule := []string{"with_additional_permissions:", "network.enabled=true", `__herm_read="/tmp/read.txt"`, "cat"}
	if len(prefixRules) != 1 || !slices.Equal(prefixRules[0], wantRule) {
		t.Fatalf("additional-permission prefix rules = %#v, want %#v", prefixRules, [][]string{wantRule})
	}

	spacedPath := filepath.Join(t.TempDir(), "read token.txt")
	spacedPermissions := bashAdditionalPermissions{
		FileSystem: bashFileSystemPermissions{Read: []string{spacedPath}},
	}
	paths := commandExternalPaths(commandExternalPathsOptions{
		command: bashApprovalCommand(bashApprovalCommandOptions{
			command:               "cat data",
			sandboxPermissions:    bashSandboxPermissionsWithAdditional,
			additionalPermissions: spacedPermissions,
		}),
		workspace: t.TempDir(),
	})
	if !slices.Equal(paths, []string{spacedPath}) {
		t.Fatalf("additional-permission paths = %#v, want %#v", paths, []string{spacedPath})
	}
}

func TestNakedBashApprovalDescriptionsIncludeModeAndJustification(t *testing.T) {
	input := json.RawMessage(`{"command":"cat /tmp/token.txt","sandbox_permissions":"require_escalated","prefix_rule":["cat"],"justification":"Allow reading this outside-workspace token?"}`)
	desc := approvalCmdDesc(approvalCmdDescOptions{toolName: toolBash, input: input})
	if !strings.Contains(desc, "Allow reading this outside-workspace token?") ||
		!strings.Contains(desc, "require_escalated: cat /tmp/token.txt") ||
		!strings.Contains(desc, "prefix_rule: cat") {
		t.Fatalf("approval desc = %q", desc)
	}
	short := approvalShortDesc(approvalShortDescOptions{toolName: toolBash, input: input})
	if short != "bash require_escalated: cat /tmp/token.txt" {
		t.Fatalf("approval short desc = %q", short)
	}
}

func TestRequestPermissionsApprovalDescription(t *testing.T) {
	input := json.RawMessage(`{"permissions":{"network":{"enabled":true},"file_system":{"read":["/tmp/read.txt"],"write":["/tmp/write.txt"]}}}`)
	desc := approvalCmdDesc(approvalCmdDescOptions{toolName: toolRequestPermissions, input: input})
	for _, want := range []string{"request_permissions:", "network.enabled", "read /tmp/read.txt", "write /tmp/write.txt"} {
		if !strings.Contains(desc, want) {
			t.Fatalf("approval desc missing %q: %q", want, desc)
		}
	}
	short := approvalShortDesc(approvalShortDescOptions{toolName: toolRequestPermissions, input: input})
	if short != "request permissions" {
		t.Fatalf("approval short desc = %q", short)
	}
}

func TestNakedBashToolDefinitionIncludesEscalationFields(t *testing.T) {
	tool := NewNakedBashTool(NewNakedBashToolOptions{WorkDir: t.TempDir()})
	schema := string(tool.Definition().InputSchema)
	for _, want := range []string{"sandbox_permissions", "with_additional_permissions", "additional_permissions", "file_system", "network", "require_escalated", "prefix_rule", "justification"} {
		if !strings.Contains(schema, want) {
			t.Fatalf("naked bash schema missing %q: %s", want, schema)
		}
	}
}

func TestNakedRequestPermissionsToolApprovalFlow(t *testing.T) {
	workspace := t.TempDir()
	outsideFile := filepath.Join(t.TempDir(), "token.txt")
	tool := NewNakedRequestPermissionsTool(workspace)
	input := json.RawMessage(`{"permissions":{"network":{"enabled":true},"file_system":{"read":["` + outsideFile + `"]}}}`)

	if !tool.RequiresApproval(input) {
		t.Fatal("new request_permissions call should require approval")
	}
	if err := tool.RecordApproval(recordToolApprovalOptions{input: input, remember: false}); err != nil {
		t.Fatalf("RecordApproval: %v", err)
	}
	if tool.RequiresApproval(input) {
		t.Fatal("approved request_permissions call should not require approval again before consumption")
	}
	out, err := tool.Execute(context.Background(), input)
	if err != nil {
		t.Fatalf("Execute: %v", err)
	}
	if out != `{"approved":true}` {
		t.Fatalf("output = %q", out)
	}
	readPaths, _, network := tool.permissions.RequestedSandboxPermissions()
	if !network || !slices.Equal(readPaths, []string{outsideFile}) {
		t.Fatalf("requested permissions = read %#v network %v", readPaths, network)
	}

	schema := string(tool.Definition().InputSchema)
	for _, want := range []string{"permissions", "network", "file_system", "read", "write"} {
		if !strings.Contains(schema, want) {
			t.Fatalf("request_permissions schema missing %q: %s", want, schema)
		}
	}
}

func TestNakedRequestPermissionsToolSharesStoreWithBash(t *testing.T) {
	workspace := t.TempDir()
	outsideFile := filepath.Join(t.TempDir(), "token.txt")
	store := newNakedPermissionStore(newNakedPermissionStoreOptions{path: nakedPermissionsPath(workspace), workspace: workspace})
	requestTool := NewNakedRequestPermissionsToolWithStore(newNakedRequestPermissionsToolWithStoreOptions{workDir: workspace, store: store})
	bashRunner := &fakeBashRunner{result: CommandResult{Stdout: "ok\n"}}
	bashTool := &BashTool{
		name:                toolBash,
		runner:              bashRunner,
		timeout:             120,
		descriptionFallback: "fallback",
		approvalPolicy:      store,
		hostTool:            true,
	}
	requestInput := json.RawMessage(`{"permissions":{"file_system":{"read":["` + outsideFile + `"]}}}`)

	if bashTool.approvalPolicy != store {
		t.Fatal("bash and request_permissions should share the same permission store")
	}
	if err := requestTool.RecordApproval(recordToolApprovalOptions{input: requestInput, remember: false}); err != nil {
		t.Fatalf("RecordApproval request: %v", err)
	}
	readPaths, _, _ := store.RequestedSandboxPermissions()
	if !slices.Equal(readPaths, []string{outsideFile}) {
		t.Fatalf("shared store requested read paths = %#v, want %#v", readPaths, []string{outsideFile})
	}
	store.FinishRequestedPermissionsOnce()
	if !requestTool.RequiresApproval(requestInput) {
		t.Fatal("one-shot requested permission should be consumable from shared store")
	}
}

func TestHostSandboxBashRunnerRequireEscalatedBypassesSandboxWrapper(t *testing.T) {
	origSandboxCommand := sandboxCommand
	t.Cleanup(func() { sandboxCommand = origSandboxCommand })
	sandboxCommand = func(_ context.Context, _ string, _ ...string) *exec.Cmd {
		t.Fatal("sandbox wrapper should not be used for require_escalated")
		return nil
	}

	workspace := t.TempDir()
	runner := hostSandboxBashRunner{workspace: workspace}
	result, err := runner.RunBash(context.Background(), bashRunOptions{
		command:            "printf escalated",
		timeout:            5,
		sandboxPermissions: bashSandboxPermissionsRequireEscalated,
	})
	if err != nil {
		t.Fatalf("RunBash require_escalated: %v", err)
	}
	if result.Stdout != "escalated" {
		t.Fatalf("stdout = %q, want escalated", result.Stdout)
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
	outsideReadFile := filepath.Join(t.TempDir(), "read-token.txt")
	if err := os.WriteFile(outsideReadFile, []byte("secret"), 0o600); err != nil {
		t.Fatal(err)
	}
	name, args, env, err := nakedSandboxCommand(nakedSandboxCommandOptions{
		goos:            "linux",
		workspace:       workspace,
		command:         "go test ./...",
		extraReadPaths:  []string{outsideReadFile},
		extraWritePaths: []string{outsideFile},
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
		"\x00--bind\x00" + workspace + "\x00" + workspace + "\x00",
		"\x00--ro-bind\x00" + outsideReadFile + "\x00" + outsideReadFile + "\x00",
		"\x00--bind\x00" + outsideFile + "\x00" + outsideFile + "\x00",
		"\x00--chdir\x00" + workspace + "\x00",
		"\x00bash\x00-lc\x00go test ./...\x00",
	} {
		if !strings.Contains(joined, want) {
			t.Fatalf("bubblewrap args missing %q in %#v", want, args)
		}
	}
	if strings.Contains(joined, "\x00--share-net\x00") {
		t.Fatalf("bubblewrap args enabled network without permission: %#v", args)
	}
	_, networkArgs, _, err := nakedSandboxCommand(nakedSandboxCommandOptions{
		goos:           "linux",
		workspace:      workspace,
		command:        "curl https://example.com",
		networkEnabled: true,
	})
	if err != nil {
		t.Fatalf("nakedSandboxCommand network: %v", err)
	}
	if !strings.Contains("\x00"+strings.Join(networkArgs, "\x00")+"\x00", "\x00--share-net\x00") {
		t.Fatalf("bubblewrap args = %#v, want --share-net for network permission", networkArgs)
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
		goos:            "darwin",
		workspace:       workspace,
		command:         "go test ./...",
		extraWritePaths: []string{outsideFile},
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
	if !strings.Contains(args[1], "(allow lsopen)") || !strings.Contains(args[1], "(allow appleevent-send)") {
		t.Fatalf("profile = %q, want macOS browser launch allowances", args[1])
	}
	if strings.Contains(args[1], "(allow network*)") {
		t.Fatalf("profile = %q, want network denied by default", args[1])
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
	_, networkArgs, _, err := nakedSandboxCommand(nakedSandboxCommandOptions{
		goos:           "darwin",
		workspace:      workspace,
		command:        "curl https://example.com",
		networkEnabled: true,
	})
	if err != nil {
		t.Fatalf("nakedSandboxCommand network: %v", err)
	}
	if len(networkArgs) < 2 || !strings.Contains(networkArgs[1], "(allow network*)") {
		t.Fatalf("profile = %#v, want network allowance", networkArgs)
	}
}

func TestDarwinNakedSandboxCommandConfiguresBrowserOpenShim(t *testing.T) {
	origLookPath := lookPath
	t.Cleanup(func() { lookPath = origLookPath })
	lookPath = func(file string) (string, error) {
		if file == "sandbox-exec" {
			return "/usr/bin/sandbox-exec", nil
		}
		return "", errors.New("not found")
	}

	workspace := filepath.Join(t.TempDir(), "project")
	openLog := filepath.Join(workspace, ".herm", "tmp", "browser-open.log")
	_, _, env, err := nakedSandboxCommand(nakedSandboxCommandOptions{
		goos:      "darwin",
		workspace: workspace,
		command:   "login",
		openLog:   openLog,
	})
	if err != nil {
		t.Fatalf("nakedSandboxCommand: %v", err)
	}
	shim := filepath.Join(workspace, configDir, "bin", "open")
	if !slices.Contains(env, "BROWSER="+shim) {
		t.Fatalf("env = %#v, want BROWSER shim", env)
	}
	if !slices.Contains(env, "HERM_BROWSER_OPEN_LOG="+openLog) {
		t.Fatalf("env = %#v, want browser open log", env)
	}
	foundPath := false
	for _, item := range env {
		if strings.HasPrefix(item, "PATH="+filepath.Join(workspace, configDir, "bin")+string(os.PathListSeparator)) {
			foundPath = true
		}
	}
	if !foundPath {
		t.Fatalf("env = %#v, want PATH prepended with shim dir", env)
	}
}

func TestDarwinBrowserOpenBrokerLaunchesOnlyURLs(t *testing.T) {
	origOpenCommand := darwinOpenCommand
	t.Cleanup(func() { darwinOpenCommand = origOpenCommand })

	var opened [][]string
	darwinOpenCommand = func(_ context.Context, args []string) error {
		opened = append(opened, append([]string(nil), args...))
		return nil
	}

	logPath := filepath.Join(t.TempDir(), "browser-open.log")
	content := strings.Join([]string{
		"__HERM_OPEN__",
		"https://example.com/login",
		"__HERM_DONE__",
		"__HERM_OPEN__",
		"/etc/passwd",
		"__HERM_DONE__",
		"",
	}, "\n")
	if err := os.WriteFile(logPath, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}

	broker := &darwinBrowserOpenBroker{logPath: logPath}
	broker.process()

	if len(opened) != 1 || !slices.Equal(opened[0], []string{"https://example.com/login"}) {
		t.Fatalf("opened = %#v, want only URL request", opened)
	}
	if !strings.Contains(broker.Errors(), "ignored non-URL") {
		t.Fatalf("broker errors = %q, want ignored non-URL error", broker.Errors())
	}
}
