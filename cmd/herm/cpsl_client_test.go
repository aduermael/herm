package main

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"slices"
	"strings"
	"sync"
	"testing"
)

type fakeCPSLProcess struct {
	stdinW  *io.PipeWriter
	stdoutR *io.PipeReader
	done    chan struct{}
	killMu  sync.Mutex
	killed  bool
	once    sync.Once
}

func newFakeCPSLProcess(t *testing.T, handler func(cpslWorkerRequest, *json.Encoder)) (*fakeCPSLProcess, *cpslWorkerProcess) {
	t.Helper()
	stdinR, stdinW := io.Pipe()
	stdoutR, stdoutW := io.Pipe()
	fake := &fakeCPSLProcess{stdinW: stdinW, stdoutR: stdoutR, done: make(chan struct{})}

	go func() {
		defer fake.closeDone()
		defer stdoutW.Close()
		reader := bufio.NewReader(stdinR)
		encoder := json.NewEncoder(stdoutW)
		for {
			line, err := readCPSLWorkerLine(reader)
			if err != nil {
				return
			}
			var request cpslWorkerRequest
			if err := json.Unmarshal(line, &request); err != nil {
				return
			}
			handler(request, encoder)
		}
	}()

	proc := &cpslWorkerProcess{
		stdin:  stdinW,
		stdout: stdoutR,
		kill: func() error {
			fake.killMu.Lock()
			fake.killed = true
			fake.killMu.Unlock()
			_ = stdinR.Close()
			_ = stdoutW.Close()
			_ = stdoutR.Close()
			fake.closeDone()
			return nil
		},
		wait: func() error {
			<-fake.done
			return nil
		},
	}
	return fake, proc
}

func (f *fakeCPSLProcess) closeDone() {
	f.once.Do(func() { close(f.done) })
}

func (f *fakeCPSLProcess) wasKilled() bool {
	f.killMu.Lock()
	defer f.killMu.Unlock()
	return f.killed
}

func withFakeCPSLProcess(t *testing.T, proc *cpslWorkerProcess) {
	t.Helper()
	withFakeCPSLProcessStart(t, func(cpslWorkerProcessOptions) (*cpslWorkerProcess, error) {
		return proc, nil
	})
}

func withFakeCPSLProcessStart(t *testing.T, start func(cpslWorkerProcessOptions) (*cpslWorkerProcess, error)) {
	t.Helper()
	orig := startCPSLWorkerProcess
	startCPSLWorkerProcess = start
	t.Cleanup(func() { startCPSLWorkerProcess = orig })
}

func TestCPSLWorkerProcessArgsPreserveRepeatedDomains(t *testing.T) {
	args := cpslWorkerProcessArgs(cpslWorkerProcessOptions{
		LibraryPath:  "/tmp/libcpsl.so",
		Workspace:    "/tmp/work",
		AllowDomains: []string{"example.com", "api.example.com"},
		DenyDomains:  []string{"blocked.example.com", "blocked-api.example.com"},
	})
	want := []string{
		"__cpsl-worker",
		"--library", "/tmp/libcpsl.so",
		"--workspace", "/tmp/work",
		"--allow-domain", "example.com",
		"--allow-domain", "api.example.com",
		"--deny-domain", "blocked.example.com",
		"--deny-domain", "blocked-api.example.com",
	}
	if !slices.Equal(args, want) {
		t.Fatalf("args = %#v, want %#v", args, want)
	}
}

func TestCPSLWorkerClientPassesDomainsToProcess(t *testing.T) {
	var got cpslWorkerProcessOptions
	_, proc := newFakeCPSLProcess(t, func(request cpslWorkerRequest, encoder *json.Encoder) {
		exitCode := 0
		_ = encoder.Encode(cpslEvalResponse{
			ID:       request.ID,
			OK:       true,
			Stdout:   "/workdir\n",
			Stderr:   "",
			ExitCode: &exitCode,
			Warnings: []string{},
			CWD:      "/workdir",
		})
	})
	withFakeCPSLProcessStart(t, func(opts cpslWorkerProcessOptions) (*cpslWorkerProcess, error) {
		got = opts
		return proc, nil
	})

	client, err := NewCPSLWorkerClient(newCPSLWorkerClientOptions{
		LibraryPath:  "/tmp/libcpsl.so",
		Workspace:    "/tmp/work",
		AllowDomains: []string{"example.com", "api.example.com"},
		DenyDomains:  []string{"blocked.example.com", "blocked-api.example.com"},
	})
	if err != nil {
		t.Fatalf("NewCPSLWorkerClient: %v", err)
	}
	defer client.Close()

	if !slices.Equal(got.AllowDomains, []string{"example.com", "api.example.com"}) {
		t.Fatalf("AllowDomains = %#v", got.AllowDomains)
	}
	if !slices.Equal(got.DenyDomains, []string{"blocked.example.com", "blocked-api.example.com"}) {
		t.Fatalf("DenyDomains = %#v", got.DenyDomains)
	}
}

func TestCPSLWorkerClientEvalSuccess(t *testing.T) {
	var inputs []string
	var languages []string
	_, proc := newFakeCPSLProcess(t, func(request cpslWorkerRequest, encoder *json.Encoder) {
		inputs = append(inputs, request.Input)
		languages = append(languages, request.Language)
		exitCode := 0
		_ = encoder.Encode(cpslEvalResponse{
			ID:       request.ID,
			OK:       true,
			Stdout:   request.Input + "\n",
			Stderr:   "",
			ExitCode: &exitCode,
			Warnings: []string{},
			CWD:      "/workdir",
		})
	})
	withFakeCPSLProcess(t, proc)

	client, err := NewCPSLWorkerClient(newCPSLWorkerClientOptions{LibraryPath: "/tmp/libcpsl.so", Workspace: "/tmp/work"})
	if err != nil {
		t.Fatalf("NewCPSLWorkerClient: %v", err)
	}
	defer client.Close()

	response, err := client.EvalBash(context.Background(), cpslLanguageEvalOptions{input: "echo ok", timeoutSeconds: 1})
	if err != nil {
		t.Fatalf("EvalBash: %v", err)
	}
	if !response.OK || response.Stdout != "echo ok\n" {
		t.Fatalf("response = %#v", response)
	}
	response, err = client.EvalLuau(context.Background(), cpslLanguageEvalOptions{input: "print('native')", timeoutSeconds: 1})
	if err != nil {
		t.Fatalf("EvalLuau: %v", err)
	}
	if !response.OK || response.Stdout != "print('native')\n" {
		t.Fatalf("luau response = %#v", response)
	}
	if strings.Join(inputs, ",") != `print("ok"),echo ok,print('native')` {
		t.Fatalf("inputs = %#v", inputs)
	}
	if strings.Join(languages, ",") != "luau,bash,luau" {
		t.Fatalf("languages = %#v", languages)
	}
}

func TestCPSLWorkerClientTimeoutKillsWorker(t *testing.T) {
	var count int
	var fake *fakeCPSLProcess
	fake, proc := newFakeCPSLProcess(t, func(request cpslWorkerRequest, encoder *json.Encoder) {
		count++
		if count == 1 {
			exitCode := 0
			_ = encoder.Encode(cpslEvalResponse{ID: request.ID, OK: true, Stdout: "/workdir\n", ExitCode: &exitCode, Warnings: []string{}, CWD: "/workdir"})
			return
		}
		<-fake.done
	})
	withFakeCPSLProcess(t, proc)

	client, err := NewCPSLWorkerClient(newCPSLWorkerClientOptions{LibraryPath: "/tmp/libcpsl.so", Workspace: "/tmp/work"})
	if err != nil {
		t.Fatalf("NewCPSLWorkerClient: %v", err)
	}

	response, err := client.eval(context.Background(), cpslWorkerRequest{Op: "eval", Language: "bash", Input: "sleep", TimeoutMS: 5})
	if err == nil {
		t.Fatal("Eval returned nil error")
	}
	if response.Error == nil || response.Error.Code != "timeout" {
		t.Fatalf("response = %#v", response)
	}
	if !fake.wasKilled() {
		t.Fatal("worker was not killed")
	}
}

func TestCPSLWorkerClientStartupFailureUsesLibraryError(t *testing.T) {
	fake, proc := newFakeCPSLProcess(t, func(cpslWorkerRequest, *json.Encoder) {})
	_ = proc.stdin.Close()
	_ = fake.stdoutR.Close()
	fake.closeDone()
	withFakeCPSLProcess(t, proc)

	_, err := NewCPSLWorkerClient(newCPSLWorkerClientOptions{LibraryPath: "/tmp/libcpsl.so", Workspace: "/tmp/work"})
	if err != errCPSLLibrary {
		t.Fatalf("NewCPSLWorkerClient err = %v, want errCPSLLibrary", err)
	}
}

func TestCPSLWorkerClientMalformedResponseMarksDead(t *testing.T) {
	var count int
	fake, proc := newFakeCPSLProcess(t, func(request cpslWorkerRequest, encoder *json.Encoder) {
		count++
		if count == 1 {
			exitCode := 0
			_ = encoder.Encode(cpslEvalResponse{ID: request.ID, OK: true, Stdout: "/workdir\n", ExitCode: &exitCode, Warnings: []string{}, CWD: "/workdir"})
			return
		}
		_ = encoder.Encode(map[string]any{"id": request.ID + 1, "ok": true})
	})
	withFakeCPSLProcess(t, proc)

	client, err := NewCPSLWorkerClient(newCPSLWorkerClientOptions{LibraryPath: "/tmp/libcpsl.so", Workspace: "/tmp/work"})
	if err != nil {
		t.Fatalf("NewCPSLWorkerClient: %v", err)
	}

	_, err = client.eval(context.Background(), cpslWorkerRequest{Op: "eval", Language: "bash", Input: "bad", TimeoutMS: 1000})
	if err == nil {
		t.Fatal("Eval returned nil error")
	}
	if !fake.wasKilled() {
		t.Fatal("worker was not killed")
	}

	_, err = client.eval(context.Background(), cpslWorkerRequest{Op: "eval", Language: "bash", Input: "again", TimeoutMS: 1000})
	if err == nil || !strings.Contains(err.Error(), "not running") {
		t.Fatalf("second eval err = %v, want not running", err)
	}
}
