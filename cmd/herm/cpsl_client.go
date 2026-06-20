// cpsl_client.go manages the subprocess client used to evaluate CPSL requests
// without blocking Herm's main process or terminal event loop.
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

type cpslWorkerBackend interface {
	cpslEvaluator
	Close() error
}

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
		Language:  cpslLanguageLuau,
		Input:     `print("ok")`,
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

	args := cpslWorkerProcessArgs(opts)
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

func cpslWorkerProcessArgs(opts cpslWorkerProcessOptions) []string {
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
	return args
}

type cpslLanguageEvalOptions struct {
	input          string
	timeoutSeconds int
}

type cpslEvalOptions struct {
	language       string
	input          string
	timeoutSeconds int
}

func (c *CPSLWorkerClient) EvalBash(ctx context.Context, opts cpslLanguageEvalOptions) (cpslEvalResponse, error) {
	return c.EvalCPSL(ctx, cpslEvalOptions{language: cpslLanguageBash, input: opts.input, timeoutSeconds: opts.timeoutSeconds})
}

func (c *CPSLWorkerClient) EvalLuau(ctx context.Context, opts cpslLanguageEvalOptions) (cpslEvalResponse, error) {
	return c.EvalCPSL(ctx, cpslEvalOptions{language: cpslLanguageLuau, input: opts.input, timeoutSeconds: opts.timeoutSeconds})
}

func (c *CPSLWorkerClient) EvalCPSL(ctx context.Context, opts cpslEvalOptions) (cpslEvalResponse, error) {
	if opts.timeoutSeconds <= 0 {
		opts.timeoutSeconds = 120
	}
	if opts.timeoutSeconds > 600 {
		opts.timeoutSeconds = 600
	}
	return c.eval(ctx, cpslWorkerRequest{
		Op:        cpslWorkerOpEval,
		Language:  opts.language,
		Input:     opts.input,
		TimeoutMS: opts.timeoutSeconds * 1000,
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
		response := cpslErrorResponse(cpslErrorResponseOptions{id: request.ID, code: "runtime_error", message: "CPSL worker is not running"})
		return response, newCPSLWorkerError(cpslWorkerErrorOptions{code: "runtime_error", message: "CPSL worker is not running"})
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
		return cpslErrorResponse(cpslErrorResponseOptions{id: request.ID, code: "runtime_error", message: err.Error()}), err
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
		response := cpslTimeoutResponse(cpslTimeoutResponseOptions{id: request.ID, timeoutMS: request.TimeoutMS})
		return response, newCPSLWorkerError(cpslWorkerErrorOptions{code: response.Error.Code, message: response.Error.Message})
	case result := <-readCh:
		if result.err != nil {
			c.markDeadLocked()
			return cpslErrorResponse(cpslErrorResponseOptions{id: request.ID, code: "runtime_error", message: result.err.Error()}), result.err
		}
		response, err := decodeCPSLEvalResponse(decodeCPSLEvalResponseOptions{data: result.line, requestID: request.ID})
		if err != nil {
			c.markDeadLocked()
			return cpslErrorResponse(cpslErrorResponseOptions{id: request.ID, code: "runtime_error", message: err.Error()}), err
		}
		if response.Error != nil && response.Error.Code == "timeout" {
			c.markDeadLocked()
			return response, newCPSLWorkerError(cpslWorkerErrorOptions{code: response.Error.Code, message: response.Error.Message})
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
