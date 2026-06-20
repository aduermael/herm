// cpsl_worker.go implements the hidden Herm subprocess that owns the CPSL
// native session and speaks a newline-delimited JSON protocol.
package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type cpslSessionEvaluator interface {
	eval(opts cpslSessionEvalOptions) (string, error)
}

type cpslSessionEvalOptions struct {
	session     cpslSession
	requestJSON string
}

type cpslWorkerOptions struct {
	libraryPath  string
	workspace    string
	allowDomains []string
	denyDomains  []string
}

const cpslLibraryDirEnv = "CPSL_LIBRARY_DIR"

type runCPSLWorkerOptions struct {
	args   []string
	stdin  io.Reader
	stdout io.Writer
	stderr io.Writer
}

func runCPSLWorker(opts runCPSLWorkerOptions) int {
	workerOpts, err := parseCPSLWorkerOptions(parseCPSLWorkerArgsOptions{args: opts.args, stderr: opts.stderr})
	if err != nil {
		return 2
	}

	workspace, err := canonicalWorkspace(workerOpts.workspace)
	if err != nil {
		fmt.Fprintf(opts.stderr, "cpsl worker: workspace: %v\n", err)
		return 2
	}

	setCPSLLibraryDirEnv(workerOpts.libraryPath)
	lib, err := loadCPSLNativeLibrary(workerOpts.libraryPath)
	if err != nil {
		fmt.Fprintf(opts.stderr, "cpsl worker: library: %v\n", err)
		return 2
	}
	defer func() { _ = lib.close() }()

	configJSON, err := cpslSessionConfigJSON(cpslSessionConfigJSONOptions{
		workspace:    workspace,
		allowDomains: workerOpts.allowDomains,
		denyDomains:  workerOpts.denyDomains,
	})
	if err != nil {
		fmt.Fprintf(opts.stderr, "cpsl worker: session config: %v\n", err)
		return 2
	}

	session, err := lib.sessionNew(configJSON)
	if err != nil {
		fmt.Fprintf(opts.stderr, "cpsl worker: session: %v\n", err)
		return 2
	}
	defer lib.sessionFree(session)

	if err := serveCPSLWorkerPlatform(serveCPSLWorkerOptions{
		evaluator:   lib,
		session:     session,
		stdin:       opts.stdin,
		stdout:      opts.stdout,
		stderr:      opts.stderr,
		exitProcess: os.Exit,
	}); err != nil {
		if errors.Is(err, errCPSLWorkerTerminated) {
			return 0
		}
		fmt.Fprintf(opts.stderr, "cpsl worker: protocol: %v\n", err)
		return 1
	}
	return 0
}

type parseCPSLWorkerArgsOptions struct {
	args   []string
	stderr io.Writer
}

func parseCPSLWorkerOptions(opts parseCPSLWorkerArgsOptions) (cpslWorkerOptions, error) {
	fs := flag.NewFlagSet("cpsl-worker", flag.ContinueOnError)
	fs.SetOutput(opts.stderr)
	var workerOpts cpslWorkerOptions
	var allowDomains stringListFlag
	var denyDomains stringListFlag
	fs.StringVar(&workerOpts.libraryPath, "library", "", "path to CPSL dynamic library")
	fs.StringVar(&workerOpts.workspace, "workspace", "", "host workspace mounted at /workdir")
	fs.Var(&allowDomains, "allow-domain", "allowed domain")
	fs.Var(&denyDomains, "deny-domain", "denied domain")
	if err := fs.Parse(opts.args); err != nil {
		return cpslWorkerOptions{}, err
	}
	workerOpts.allowDomains = append([]string(nil), allowDomains...)
	workerOpts.denyDomains = append([]string(nil), denyDomains...)
	if workerOpts.libraryPath == "" {
		return cpslWorkerOptions{}, fmt.Errorf("missing CPSL library path")
	}
	if workerOpts.workspace == "" {
		return cpslWorkerOptions{}, fmt.Errorf("missing CPSL workspace")
	}
	return workerOpts, nil
}

func setCPSLLibraryDirEnv(libraryPath string) {
	if libraryPath == "" {
		return
	}
	_ = os.Setenv(cpslLibraryDirEnv, filepath.Dir(libraryPath))
}

type serveCPSLWorkerOptions struct {
	evaluator   cpslSessionEvaluator
	session     cpslSession
	stdin       io.Reader
	stdout      io.Writer
	stderr      io.Writer
	exitProcess func(int)
}

var errCPSLWorkerTerminated = errors.New("CPSL worker terminated after response")

func serveCPSLWorker(opts serveCPSLWorkerOptions) error {
	reader := bufio.NewReader(opts.stdin)
	encoder := json.NewEncoder(opts.stdout)
	for {
		line, err := readCPSLWorkerLine(reader)
		if err != nil {
			if err == io.EOF {
				return nil
			}
			return err
		}
		if strings.TrimSpace(string(line)) == "" {
			continue
		}

		var request cpslWorkerRequest
		if err := json.Unmarshal(line, &request); err != nil {
			response := cpslErrorResponse(cpslErrorResponseOptions{id: 0, code: "invalid_request", message: "Malformed worker request"})
			if encodeErr := encoder.Encode(response); encodeErr != nil {
				return encodeErr
			}
			continue
		}

		action := handleCPSLWorkerRequest(handleCPSLWorkerRequestOptions{
			evaluator: opts.evaluator,
			session:   opts.session,
			request:   request,
		})
		if err := encoder.Encode(action.response); err != nil {
			return err
		}
		if action.terminate {
			if opts.exitProcess != nil {
				opts.exitProcess(0)
			}
			return errCPSLWorkerTerminated
		}
	}
}

type cpslWorkerAction struct {
	response  cpslEvalResponse
	terminate bool
}

type handleCPSLWorkerRequestOptions struct {
	evaluator cpslSessionEvaluator
	session   cpslSession
	request   cpslWorkerRequest
}

func handleCPSLWorkerRequest(opts handleCPSLWorkerRequestOptions) cpslWorkerAction {
	if opts.request.Op != cpslWorkerOpEval {
		return cpslWorkerAction{response: cpslErrorResponse(cpslErrorResponseOptions{id: opts.request.ID, code: "invalid_request", message: "Unsupported CPSL worker operation"})}
	}
	if !isSupportedCPSLLanguage(opts.request.Language) {
		return cpslWorkerAction{response: cpslErrorResponse(cpslErrorResponseOptions{id: opts.request.ID, code: "unsupported_language", message: "Supported CPSL worker languages are luau and bash"})}
	}
	if opts.request.TimeoutMS <= 0 {
		return cpslWorkerAction{response: cpslErrorResponse(cpslErrorResponseOptions{id: opts.request.ID, code: "invalid_request", message: "timeout_ms must be positive"})}
	}

	done := make(chan cpslEvalResponse, 1)
	go func() {
		done <- evalCPSLWorkerRequest(evalCPSLWorkerRequestOptions{
			evaluator: opts.evaluator,
			session:   opts.session,
			request:   opts.request,
		})
	}()

	timer := time.NewTimer(time.Duration(opts.request.TimeoutMS) * time.Millisecond)
	defer timer.Stop()

	select {
	case response := <-done:
		return cpslWorkerAction{response: response}
	case <-timer.C:
		return cpslWorkerAction{response: cpslTimeoutResponse(cpslTimeoutResponseOptions{id: opts.request.ID, timeoutMS: opts.request.TimeoutMS}), terminate: true}
	}
}

type evalCPSLWorkerRequestOptions struct {
	evaluator cpslSessionEvaluator
	session   cpslSession
	request   cpslWorkerRequest
}

func evalCPSLWorkerRequest(opts evalCPSLWorkerRequestOptions) cpslEvalResponse {
	evalRequest := struct {
		Language  string `json:"language"`
		Input     string `json:"input"`
		TimeoutMS int    `json:"timeout_ms"`
	}{
		Language:  opts.request.Language,
		Input:     opts.request.Input,
		TimeoutMS: opts.request.TimeoutMS,
	}
	requestJSON, err := json.Marshal(evalRequest)
	if err != nil {
		return cpslErrorResponse(cpslErrorResponseOptions{id: opts.request.ID, code: "invalid_request", message: err.Error()})
	}

	responseJSON, err := opts.evaluator.eval(cpslSessionEvalOptions{session: opts.session, requestJSON: string(requestJSON)})
	if err != nil {
		return cpslErrorResponse(cpslErrorResponseOptions{id: opts.request.ID, code: "runtime_error", message: err.Error()})
	}

	var response cpslEvalResponse
	if err := json.Unmarshal([]byte(responseJSON), &response); err != nil {
		return cpslErrorResponse(cpslErrorResponseOptions{id: opts.request.ID, code: "runtime_error", message: fmt.Sprintf("CPSL returned malformed response: %v", err)})
	}
	response.ID = opts.request.ID
	if response.Warnings == nil {
		response.Warnings = []string{}
	}
	if response.CWD == "" {
		response.CWD = cpslWorkerInitialCW
	}
	return response
}

const cpslWorkerMaxLineBytes = 16 * 1024 * 1024

func readCPSLWorkerLine(reader *bufio.Reader) ([]byte, error) {
	var line []byte
	for {
		part, err := reader.ReadSlice('\n')
		line = append(line, part...)
		if len(line) > cpslWorkerMaxLineBytes {
			return nil, fmt.Errorf("CPSL worker line exceeded %d bytes", cpslWorkerMaxLineBytes)
		}
		if err == nil {
			return line, nil
		}
		if err != bufio.ErrBufferFull {
			if err == io.EOF && len(line) > 0 {
				return line, nil
			}
			return nil, err
		}
	}
}

func canonicalWorkspace(workspace string) (string, error) {
	abs, err := filepath.Abs(workspace)
	if err != nil {
		return "", err
	}
	resolved, err := filepath.EvalSymlinks(abs)
	if err != nil {
		return "", err
	}
	info, err := os.Stat(resolved)
	if err != nil {
		return "", err
	}
	if !info.IsDir() {
		return "", fmt.Errorf("%s is not a directory", resolved)
	}
	return resolved, nil
}
