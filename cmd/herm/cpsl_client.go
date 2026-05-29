package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"sync"
	"time"
)

const cpslWorkerStartupTimeout = 10 * time.Second

type CPSLWorkerClient struct {
	stdin  io.WriteCloser
	stdout *bufio.Reader
	kill   func() error
	wait   func() error

	mu     sync.Mutex
	nextID int64
	dead   bool
}

type newCPSLWorkerClientOptions struct {
	LibraryPath  string
	Workspace    string
	AllowDomains []string
	DenyDomains  []string
}

type cpslWorkerProcess struct {
	stdin  io.WriteCloser
	stdout io.Reader
	kill   func() error
	wait   func() error
}

type cpslWorkerProcessOptions struct {
	LibraryPath  string
	Workspace    string
	AllowDomains []string
	DenyDomains  []string
}

var startCPSLWorkerProcess = startCPSLWorkerOSProcess

func NewCPSLWorkerClient(opts newCPSLWorkerClientOptions) (*CPSLWorkerClient, error) {
	proc, err := startCPSLWorkerProcess(cpslWorkerProcessOptions{
		LibraryPath:  opts.LibraryPath,
		Workspace:    opts.Workspace,
		AllowDomains: append([]string(nil), opts.AllowDomains...),
		DenyDomains:  append([]string(nil), opts.DenyDomains...),
	})
	if err != nil {
		return nil, err
	}

	client := &CPSLWorkerClient{
		stdin:  proc.stdin,
		stdout: bufio.NewReader(proc.stdout),
		kill:   proc.kill,
		wait:   proc.wait,
	}

	ctx, cancel := context.WithTimeout(context.Background(), cpslWorkerStartupTimeout)
	defer cancel()
	response, err := client.eval(ctx, cpslWorkerRequest{
		Op:        cpslWorkerOpEval,
		Language:  cpslWorkerLanguage,
		Input:     "pwd",
		TimeoutMS: int(cpslWorkerStartupTimeout / time.Millisecond),
	})
	if err != nil || !response.OK {
		_ = client.Close()
		return nil, errCPSLLibrary
	}
	return client, nil
}

func startCPSLWorkerOSProcess(opts cpslWorkerProcessOptions) (*cpslWorkerProcess, error) {
	exe, err := os.Executable()
	if err != nil {
		return nil, err
	}

	args := []string{
		"__cpsl-worker",
		"--library", opts.LibraryPath,
		"--workspace", opts.Workspace,
	}
	for _, domain := range opts.AllowDomains {
		args = append(args, "--allow-domain", domain)
	}
	for _, domain := range opts.DenyDomains {
		args = append(args, "--deny-domain", domain)
	}

	cmd := exec.Command(exe, args...)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	go func() { _, _ = io.Copy(io.Discard, stderr) }()

	return &cpslWorkerProcess{
		stdin:  stdin,
		stdout: stdout,
		kill: func() error {
			if cmd.Process == nil {
				return nil
			}
			return cmd.Process.Kill()
		},
		wait: cmd.Wait,
	}, nil
}

func (c *CPSLWorkerClient) EvalBash(ctx context.Context, input string, timeoutSeconds int) (cpslEvalResponse, error) {
	if timeoutSeconds <= 0 {
		timeoutSeconds = 120
	}
	if timeoutSeconds > 600 {
		timeoutSeconds = 600
	}
	return c.eval(ctx, cpslWorkerRequest{
		Op:        cpslWorkerOpEval,
		Language:  cpslWorkerLanguage,
		Input:     input,
		TimeoutMS: timeoutSeconds * 1000,
	})
}

func (c *CPSLWorkerClient) eval(ctx context.Context, request cpslWorkerRequest) (cpslEvalResponse, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	if request.TimeoutMS <= 0 {
		request.TimeoutMS = 120000
	}

	c.mu.Lock()
	defer c.mu.Unlock()

	if c.dead {
		return cpslErrorResponse(request.ID, "runtime_error", "CPSL worker is not running"), newCPSLWorkerError("runtime_error", "CPSL worker is not running")
	}

	c.nextID++
	request.ID = c.nextID
	data, err := json.Marshal(request)
	if err != nil {
		return cpslEvalResponse{}, err
	}

	callCtx, cancel := context.WithTimeout(ctx, time.Duration(request.TimeoutMS)*time.Millisecond)
	defer cancel()

	if _, err := fmt.Fprintln(c.stdin, string(data)); err != nil {
		c.markDeadLocked()
		return cpslErrorResponse(request.ID, "runtime_error", err.Error()), err
	}

	type readResult struct {
		line []byte
		err  error
	}
	readCh := make(chan readResult, 1)
	go func() {
		line, err := readCPSLWorkerLine(c.stdout)
		readCh <- readResult{line: line, err: err}
	}()

	select {
	case <-callCtx.Done():
		c.markDeadLocked()
		response := cpslTimeoutResponse(request.ID, request.TimeoutMS)
		return response, newCPSLWorkerError(response.Error.Code, response.Error.Message)
	case result := <-readCh:
		if result.err != nil {
			c.markDeadLocked()
			return cpslErrorResponse(request.ID, "runtime_error", result.err.Error()), result.err
		}
		response, err := decodeCPSLEvalResponse(result.line, request.ID)
		if err != nil {
			c.markDeadLocked()
			return cpslErrorResponse(request.ID, "runtime_error", err.Error()), err
		}
		if response.Error != nil && response.Error.Code == "timeout" {
			c.markDeadLocked()
			return response, newCPSLWorkerError(response.Error.Code, response.Error.Message)
		}
		return response, nil
	}
}

func (c *CPSLWorkerClient) Close() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.closeLocked()
}

func (c *CPSLWorkerClient) markDeadLocked() {
	c.dead = true
	if c.kill != nil {
		_ = c.kill()
	}
	if c.wait != nil {
		go func() { _ = c.wait() }()
	}
}

func (c *CPSLWorkerClient) closeLocked() error {
	if c.dead {
		return nil
	}
	c.dead = true
	if c.stdin != nil {
		_ = c.stdin.Close()
	}
	if c.wait == nil {
		return nil
	}

	done := make(chan error, 1)
	go func() { done <- c.wait() }()
	select {
	case err := <-done:
		return err
	case <-time.After(time.Second):
		if c.kill != nil {
			_ = c.kill()
		}
		return <-done
	}
}
