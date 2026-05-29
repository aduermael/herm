package main

import (
	"testing"
	"time"
)

func TestCPSLBackendDoesNotBootContainer(t *testing.T) {
	origBootContainer := bootContainer
	t.Cleanup(func() { bootContainer = origBootContainer })

	called := false
	bootContainer = func(bootContainerCmdOptions) {
		called = true
	}

	app := &App{
		backend:   backendCPSL,
		sessionID: "session",
		resultCh:  make(chan any, 1),
		stopCh:    make(chan struct{}),
	}
	app.startBackendForWorkspace(t.TempDir())

	if called {
		t.Fatal("CPSL backend started container boot")
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

func toolNameSet(tools []Tool) map[string]bool {
	names := make(map[string]bool, len(tools))
	for _, tool := range tools {
		names[tool.Definition().Name] = true
	}
	return names
}
