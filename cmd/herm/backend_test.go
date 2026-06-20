package main

import (
	"bytes"
	"slices"
	"strings"
	"testing"
	"time"
)

func TestCPSLBackendStartsWorkerAndDoesNotBootContainer(t *testing.T) {
	origBootContainer := bootContainer
	origBootCPSLWorker := bootCPSLWorker
	t.Cleanup(func() {
		bootContainer = origBootContainer
		bootCPSLWorker = origBootCPSLWorker
	})

	containerCalled := false
	bootContainer = func(bootContainerCmdOptions) {
		containerCalled = true
	}
	workerCalled := make(chan bootCPSLWorkerCmdOptions, 1)
	bootCPSLWorker = func(opts bootCPSLWorkerCmdOptions) {
		workerCalled <- opts
	}

	app := &App{
		backend: backendCPSL,
		cpsl: cpslConfig{
			LibraryPath:  "/tmp/libcpsl.so",
			AllowDomains: []string{"example.com", "api.example.com"},
			DenyDomains:  []string{"blocked.example.com"},
		},
		sessionID: "session",
		resultCh:  make(chan any, 1),
		stopCh:    make(chan struct{}),
	}
	workspace := t.TempDir()
	app.startBackendForWorkspace(workspace)

	if containerCalled {
		t.Fatal("CPSL backend started container boot")
	}
	select {
	case opts := <-workerCalled:
		if opts.workspace != workspace {
			t.Fatalf("workspace = %q, want %q", opts.workspace, workspace)
		}
		if opts.config.LibraryPath != "/tmp/libcpsl.so" {
			t.Fatalf("LibraryPath = %q", opts.config.LibraryPath)
		}
		if !slices.Equal(opts.config.AllowDomains, []string{"example.com", "api.example.com"}) {
			t.Fatalf("AllowDomains = %#v", opts.config.AllowDomains)
		}
		if !slices.Equal(opts.config.DenyDomains, []string{"blocked.example.com"}) {
			t.Fatalf("DenyDomains = %#v", opts.config.DenyDomains)
		}
	case <-time.After(time.Second):
		t.Fatal("CPSL backend did not start worker")
	}
}

func TestContainerBackendBootsContainer(t *testing.T) {
	origBootContainer := bootContainer
	t.Cleanup(func() { bootContainer = origBootContainer })

	called := make(chan bootContainerCmdOptions, 1)
	bootContainer = func(opts bootContainerCmdOptions) {
		called <- opts
	}

	workspace := t.TempDir()
	app := &App{
		backend:   backendContainer,
		sessionID: "session",
		resultCh:  make(chan any, 1),
		stopCh:    make(chan struct{}),
	}
	app.startBackendForWorkspace(workspace)

	select {
	case opts := <-called:
		if opts.workspace != workspace {
			t.Fatalf("workspace = %q, want %q", opts.workspace, workspace)
		}
		if opts.sessionID != "session" {
			t.Fatalf("sessionID = %q, want session", opts.sessionID)
		}
	case <-time.After(time.Second):
		t.Fatal("container backend did not start container boot")
	}
}

func TestCPSLRuntimeToolsExcludeContainerToolsBeforeWorker(t *testing.T) {
	app := &App{
		backend:        backendCPSL,
		containerReady: true,
		container:      NewContainerClient(ContainerConfig{Image: "test:latest"}),
		worktreePath:   t.TempDir(),
		resultCh:       make(chan any, 1),
		sessionID:      "session",
	}

	if tools := app.runtimeTools(); len(tools) != 0 {
		t.Fatalf("runtimeTools returned %d tools in CPSL mode before worker, want 0", len(tools))
	}
}

func TestCPSLRuntimeToolsExposeLocalSandboxToolsAfterWorkerReady(t *testing.T) {
	app := &App{
		backend:        backendCPSL,
		containerReady: true,
		container:      NewContainerClient(ContainerConfig{Image: "test:latest"}),
		cpslReady:      true,
		cpslWorker:     &CPSLWorkerClient{},
		worktreePath:   t.TempDir(),
		resultCh:       make(chan any, 1),
		sessionID:      "session",
	}

	tools := app.runtimeTools()
	names := toolNameSet(tools)
	if len(names) != 1 || !names[toolLocalSandboxExec] {
		t.Fatalf("runtimeTools names = %#v, want local_sandbox_exec only", names)
	}
	if got := tools[0].Definition().Name; got != toolLocalSandboxExec {
		t.Fatalf("first CPSL runtime tool = %q, want %s", got, toolLocalSandboxExec)
	}
	for _, forbidden := range []string{toolLocalSandboxExecBash, toolBash, "luau", "glob", "grep", "read_file", "outline", "edit_file", "write_file", "devenv", "git"} {
		if names[forbidden] {
			t.Fatalf("runtimeTools exposed %q in CPSL mode", forbidden)
		}
	}
}

func TestAppCleanupClosesCPSLWorker(t *testing.T) {
	closed := false
	app := &App{
		stopCh: make(chan struct{}),
		cpslWorker: &CPSLWorkerClient{
			stdin: testWriteCloser{closeFunc: func() { closed = true }},
			wait:  func() error { return nil },
		},
	}

	app.cleanup()

	if !closed {
		t.Fatal("cleanup did not close CPSL worker")
	}
}

type testWriteCloser struct {
	closeFunc func()
}

func (testWriteCloser) Write(p []byte) (int, error) { return len(p), nil }
func (w testWriteCloser) Close() error {
	if w.closeFunc != nil {
		w.closeFunc()
	}
	return nil
}

func TestContainerRuntimeToolsUnchangedWhenReady(t *testing.T) {
	t.Chdir(t.TempDir())
	app := &App{
		backend:        backendContainer,
		containerReady: true,
		container:      NewContainerClient(ContainerConfig{Image: "test:latest"}),
		worktreePath:   t.TempDir(),
		resultCh:       make(chan any, 1),
		sessionID:      "session",
	}

	names := toolNameSet(app.runtimeTools())
	for _, name := range []string{
		"bash",
		"glob",
		"grep",
		"read_file",
		"outline",
		"edit_file",
		"write_file",
		"devenv",
		"git",
	} {
		if !names[name] {
			t.Fatalf("runtimeTools missing %q in container mode", name)
		}
	}
}

func TestVersionDisplayMessageCPSLUsesSandboxLabel(t *testing.T) {
	msg := versionDisplayMessage(backendCPSL)
	if !strings.Contains(msg.content, "sandbox: CPSL") {
		t.Fatalf("version message = %q, want CPSL sandbox label", msg.content)
	}
	if strings.Contains(msg.content, "container") || strings.Contains(msg.content, "local sandbox: Luau") {
		t.Fatalf("version message = %q, should not mention container or old sandbox label", msg.content)
	}
}

func TestCPSLCommandAutocompleteExcludesUnavailableCommands(t *testing.T) {
	matches := filterCommandsForBackend(filterCommandsOptions{prefix: "/", backend: backendCPSL})
	seen := make(map[string]bool, len(matches))
	for _, match := range matches {
		seen[match] = true
	}
	if !seen["/shell"] {
		t.Fatalf("CPSL autocomplete did not include /shell in %v", matches)
	}
	for _, forbidden := range []string{"/branches", "/worktrees"} {
		if seen[forbidden] {
			t.Fatalf("CPSL autocomplete included unavailable command %q in %v", forbidden, matches)
		}
	}
}

func TestCPSLShellLanguageFromInputDefaultsToLuau(t *testing.T) {
	tests := []struct {
		input string
		want  string
	}{
		{input: "/shell", want: cpslLanguageLuau},
		{input: "/shell --luau", want: cpslLanguageLuau},
		{input: "/shell --lua", want: cpslLanguageLuau},
		{input: "/shell --bash", want: cpslLanguageBash},
	}

	for _, tt := range tests {
		got, err := cpslShellLanguageFromInput(tt.input)
		if err != nil {
			t.Fatalf("cpslShellLanguageFromInput(%q): %v", tt.input, err)
		}
		if got != tt.want {
			t.Fatalf("cpslShellLanguageFromInput(%q) = %q, want %q", tt.input, got, tt.want)
		}
	}
}

func TestRunCPSLShellDefaultsToLuauThroughWorker(t *testing.T) {
	exitCode := 0
	worker := &fakeCPSLBashEvaluator{
		response: cpslEvalResponse{
			OK:       true,
			Stdout:   "3\n",
			ExitCode: &exitCode,
			CWD:      "/workdir/reports",
		},
	}
	var output bytes.Buffer

	err := runCPSLShell(runCPSLShellOptions{
		evaluator:      worker,
		input:          strings.NewReader("print(1 + 2)\nexit\n"),
		output:         &output,
		timeoutSeconds: 33,
	})

	if err != nil {
		t.Fatalf("runCPSLShell: %v", err)
	}
	if worker.command != "print(1 + 2)" {
		t.Fatalf("command = %q, want Luau line", worker.command)
	}
	if worker.language != cpslLanguageLuau {
		t.Fatalf("language = %q, want luau", worker.language)
	}
	if worker.timeout != 33 {
		t.Fatalf("timeout = %d, want 33", worker.timeout)
	}
	got := output.String()
	if !strings.Contains(got, "Local sandbox Luau") || !strings.Contains(got, "3\n") || !strings.Contains(got, "sandbox:/workdir/reports>") {
		t.Fatalf("sandbox Luau shell output = %q, want stdout and updated cwd prompt", got)
	}
}

func TestRunCPSLShellRoutesExplicitBashThroughWorker(t *testing.T) {
	exitCode := 0
	worker := &fakeCPSLBashEvaluator{
		response: cpslEvalResponse{
			OK:       true,
			Stdout:   "/workdir\n",
			ExitCode: &exitCode,
			CWD:      "/workdir/reports",
		},
	}
	var output bytes.Buffer

	err := runCPSLShell(runCPSLShellOptions{
		evaluator:      worker,
		language:       cpslLanguageBash,
		input:          strings.NewReader("pwd\nexit\n"),
		output:         &output,
		timeoutSeconds: 33,
	})

	if err != nil {
		t.Fatalf("runCPSLShell: %v", err)
	}
	if worker.command != "pwd" {
		t.Fatalf("command = %q, want pwd", worker.command)
	}
	if worker.language != cpslLanguageBash {
		t.Fatalf("language = %q, want bash", worker.language)
	}
	if got := output.String(); !strings.Contains(got, "Local sandbox Bash-compatible shell") || !strings.Contains(got, "/workdir\n") || !strings.Contains(got, "sandbox:/workdir/reports$") {
		t.Fatalf("sandbox Bash shell output = %q, want stdout and updated cwd prompt", got)
	}
}

func TestRunCPSLShellRoutesLuauThroughWorker(t *testing.T) {
	exitCode := 0
	worker := &fakeCPSLBashEvaluator{
		response: cpslEvalResponse{
			OK:       true,
			Stdout:   "3\n",
			ExitCode: &exitCode,
			CWD:      cpslWorkerInitialCW,
		},
	}
	var output bytes.Buffer

	err := runCPSLShell(runCPSLShellOptions{
		evaluator: worker,
		language:  cpslLanguageLuau,
		input:     strings.NewReader("print(1 + 2)\nexit\n"),
		output:    &output,
	})

	if err != nil {
		t.Fatalf("runCPSLShell: %v", err)
	}
	if worker.language != cpslLanguageLuau {
		t.Fatalf("language = %q, want luau", worker.language)
	}
	if worker.command != "print(1 + 2)" {
		t.Fatalf("script = %q, want Luau line", worker.command)
	}
	if got := output.String(); !strings.Contains(got, "Local sandbox Luau") || !strings.Contains(got, "sandbox:/workdir>") || !strings.Contains(got, "3\n") {
		t.Fatalf("sandbox Luau shell output = %q", got)
	}
}

func TestRunCPSLShellNonZeroAndEvalFailureDoNotFallback(t *testing.T) {
	exitCode := 7
	worker := &fakeCPSLBashEvaluator{
		response: cpslEvalResponse{
			OK:       true,
			Stderr:   "missing\n",
			ExitCode: &exitCode,
			CWD:      cpslWorkerInitialCW,
		},
	}
	var output bytes.Buffer

	err := runCPSLShell(runCPSLShellOptions{
		evaluator: worker,
		input:     strings.NewReader("missing\nexit\n"),
		output:    &output,
	})

	if err != nil {
		t.Fatalf("runCPSLShell: %v", err)
	}
	if got := output.String(); !strings.Contains(got, "missing\n") || !strings.Contains(got, "exit code: 7") {
		t.Fatalf("CPSL shell output = %q, want stderr and exit code", got)
	}
}

func TestCPSLSubAgentToolsPreserveCPSLSafeSet(t *testing.T) {
	parent := NewSubAgentTool(SubAgentConfig{
		Tools: []Tool{
			NewCPSLLuauTool(NewCPSLLuauToolOptions{Worker: nil, Timeout: 120}),
		},
		MaxDepth: 2,
		Backend:  backendCPSL,
	})

	tools := parent.buildSubAgentTools(ModeGeneral)
	names := toolNameSet(tools)
	if len(names) != 2 || !names[toolLocalSandboxExec] || !names["agent"] {
		t.Fatalf("sub-agent tool names = %#v, want local_sandbox_exec and nested agent", names)
	}
	for _, tool := range tools {
		if child, ok := tool.(*SubAgentTool); ok && child.backend != backendCPSL {
			t.Fatal("nested sub-agent did not preserve CPSL backend")
		}
	}
}

func toolNameSet(tools []Tool) map[string]bool {
	names := make(map[string]bool, len(tools))
	for _, tool := range tools {
		names[tool.Definition().Name] = true
	}
	return names
}
