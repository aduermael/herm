package main

import (
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
		backend:   backendCPSL,
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

func TestCPSLRuntimeToolsExposeOnlyBashAfterWorkerReady(t *testing.T) {
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

	names := toolNameSet(app.runtimeTools())
	if len(names) != 1 || !names["bash"] {
		t.Fatalf("runtimeTools names = %#v, want only bash", names)
	}
	for _, forbidden := range []string{"glob", "grep", "read_file", "outline", "edit_file", "write_file", "devenv", "git"} {
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

func TestCPSLCommandAutocompleteExcludesUnavailableCommands(t *testing.T) {
	matches := filterCommandsForBackend("/", backendCPSL)
	seen := make(map[string]bool, len(matches))
	for _, match := range matches {
		seen[match] = true
	}
	for _, forbidden := range []string{"/branches", "/shell", "/worktrees"} {
		if seen[forbidden] {
			t.Fatalf("CPSL autocomplete included unavailable command %q in %v", forbidden, matches)
		}
	}
}

func TestCPSLSubAgentToolsPreserveCPSLSafeSet(t *testing.T) {
	parent := NewSubAgentTool(SubAgentConfig{
		Tools:    []Tool{NewCPSLBashTool(NewCPSLBashToolOptions{Worker: nil, Timeout: 120})},
		MaxDepth: 2,
		Backend:  backendCPSL,
	})

	tools := parent.buildSubAgentTools(ModeGeneral)
	names := toolNameSet(tools)
	if len(names) != 2 || !names["bash"] || !names["agent"] {
		t.Fatalf("sub-agent tool names = %#v, want bash and nested agent", names)
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
