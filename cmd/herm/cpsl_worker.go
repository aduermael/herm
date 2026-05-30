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
	eval(session cpslSession, requestJSON string) (string, error)
}

type cpslWorkerOptions struct {
	libraryPath  string
	workspace    string
	allowDomains []string
	denyDomains  []string
}

func runCPSLWorker(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	opts, err := parseCPSLWorkerOptions(args, stderr)
	if err != nil {
		return 2
	}

	workspace, err := canonicalWorkspace(opts.workspace)
	if err != nil {
		fmt.Fprintf(stderr, "cpsl worker: workspace: %v\n", err)
		return 2
	}

	lib, err := loadCPSLNativeLibrary(opts.libraryPath)
	if err != nil {
		fmt.Fprintf(stderr, "cpsl worker: library: %v\n", err)
		return 2
	}
	defer func() { _ = lib.close() }()

	configJSON, err := cpslSessionConfigJSON(workspace, opts.allowDomains, opts.denyDomains)
	if err != nil {
		fmt.Fprintf(stderr, "cpsl worker: session config: %v\n", err)
		return 2
	}

	session, err := lib.sessionNew(configJSON)
	if err != nil {
		fmt.Fprintf(stderr, "cpsl worker: session: %v\n", err)
		return 2
	}
	defer lib.sessionFree(session)

	if err := serveCPSLWorker(serveCPSLWorkerOptions{
		evaluator:   lib,
		session:     session,
		stdin:       stdin,
		stdout:      stdout,
		stderr:      stderr,
		exitProcess: os.Exit,
	}); err != nil {
		if errors.Is(err, errCPSLWorkerTerminated) {
			return 0
		}
		fmt.Fprintf(stderr, "cpsl worker: protocol: %v\n", err)
		return 1
	}
	return 0
}

func parseCPSLWorkerOptions(args []string, stderr io.Writer) (cpslWorkerOptions, error) {
	fs := flag.NewFlagSet("cpsl-worker", flag.ContinueOnError)
	fs.SetOutput(stderr)
	var opts cpslWorkerOptions
	var allowDomains stringListFlag
	var denyDomains stringListFlag
	fs.StringVar(&opts.libraryPath, "library", "", "path to CPSL dynamic library")
	fs.StringVar(&opts.workspace, "workspace", "", "host workspace mounted at /workdir")
	fs.Var(&allowDomains, "allow-domain", "allowed domain")
	fs.Var(&denyDomains, "deny-domain", "denied domain")
	if err := fs.Parse(args); err != nil {
		return cpslWorkerOptions{}, err
	}
	opts.allowDomains = append([]string(nil), allowDomains...)
	opts.denyDomains = append([]string(nil), denyDomains...)
	if opts.libraryPath == "" {
		return cpslWorkerOptions{}, fmt.Errorf("missing CPSL library path")
	}
	if opts.workspace == "" {
		return cpslWorkerOptions{}, fmt.Errorf("missing CPSL workspace")
	}
	return opts, nil
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
			if encodeErr := encoder.Encode(cpslErrorResponse(0, "invalid_request", "Malformed worker request")); encodeErr != nil {
				return encodeErr
			}
			continue
		}

		action := handleCPSLWorkerRequest(opts.evaluator, opts.session, request)
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

func handleCPSLWorkerRequest(evaluator cpslSessionEvaluator, session cpslSession, request cpslWorkerRequest) cpslWorkerAction {
	if request.Op != cpslWorkerOpEval {
		return cpslWorkerAction{response: cpslErrorResponse(request.ID, "invalid_request", "Unsupported CPSL worker operation")}
	}
	if !isSupportedCPSLLanguage(request.Language) {
		return cpslWorkerAction{response: cpslErrorResponse(request.ID, "unsupported_language", "Supported CPSL worker languages are luau and bash")}
	}
	if request.TimeoutMS <= 0 {
		return cpslWorkerAction{response: cpslErrorResponse(request.ID, "invalid_request", "timeout_ms must be positive")}
	}

	done := make(chan cpslEvalResponse, 1)
	go func() {
		done <- evalCPSLWorkerRequest(evaluator, session, request)
	}()

	timer := time.NewTimer(time.Duration(request.TimeoutMS) * time.Millisecond)
	defer timer.Stop()

	select {
	case response := <-done:
		return cpslWorkerAction{response: response}
	case <-timer.C:
		return cpslWorkerAction{response: cpslTimeoutResponse(request.ID, request.TimeoutMS), terminate: true}
	}
}

func evalCPSLWorkerRequest(evaluator cpslSessionEvaluator, session cpslSession, request cpslWorkerRequest) cpslEvalResponse {
	evalRequest := struct {
		Language  string `json:"language"`
		Input     string `json:"input"`
		TimeoutMS int    `json:"timeout_ms"`
	}{
		Language:  request.Language,
		Input:     request.Input,
		TimeoutMS: request.TimeoutMS,
	}
	requestJSON, err := json.Marshal(evalRequest)
	if err != nil {
		return cpslErrorResponse(request.ID, "invalid_request", err.Error())
	}

	responseJSON, err := evaluator.eval(session, string(requestJSON))
	if err != nil {
		return cpslErrorResponse(request.ID, "runtime_error", err.Error())
	}

	var response cpslEvalResponse
	if err := json.Unmarshal([]byte(responseJSON), &response); err != nil {
		return cpslErrorResponse(request.ID, "runtime_error", fmt.Sprintf("CPSL returned malformed response: %v", err))
	}
	response.ID = request.ID
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
