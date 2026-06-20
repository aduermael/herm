// cpsl_protocol.go defines the JSON request and response protocol shared by
// the Herm process and the isolated CPSL worker process.
package main

import (
	"encoding/json"
	"fmt"
)

const (
	cpslABIVersion      = 1
	cpslWorkerOpEval    = "eval"
	cpslLanguageLuau    = "luau"
	cpslLanguageBash    = "bash"
	cpslWorkerInitialCW = "/workdir"
)

type cpslWorkerRequest struct {
	ID        int64  `json:"id"`
	Op        string `json:"op"`
	Language  string `json:"language"`
	Input     string `json:"input"`
	TimeoutMS int    `json:"timeout_ms"`
}

type cpslEvalResponse struct {
	ID       int64          `json:"id"`
	OK       bool           `json:"ok"`
	Stdout   string         `json:"stdout"`
	Stderr   string         `json:"stderr"`
	ExitCode *int           `json:"exit_code"`
	Error    *cpslEvalError `json:"error"`
	Warnings []string       `json:"warnings"`
	CWD      string         `json:"cwd"`
}

type cpslEvalError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

type cpslWorkerError struct {
	Code    string
	Message string
}

func (e *cpslWorkerError) Error() string {
	return e.Message
}

type cpslWorkerErrorOptions struct {
	code    string
	message string
}

func newCPSLWorkerError(opts cpslWorkerErrorOptions) *cpslWorkerError {
	return &cpslWorkerError{Code: opts.code, Message: opts.message}
}

type cpslErrorResponseOptions struct {
	id      int64
	code    string
	message string
}

func cpslErrorResponse(opts cpslErrorResponseOptions) cpslEvalResponse {
	return cpslEvalResponse{
		ID:       opts.id,
		OK:       false,
		Stdout:   "",
		Stderr:   "",
		ExitCode: nil,
		Error:    &cpslEvalError{Code: opts.code, Message: opts.message},
		Warnings: []string{},
		CWD:      cpslWorkerInitialCW,
	}
}

type cpslTimeoutResponseOptions struct {
	id        int64
	timeoutMS int
}

func cpslTimeoutResponse(opts cpslTimeoutResponseOptions) cpslEvalResponse {
	return cpslErrorResponse(cpslErrorResponseOptions{
		id:      opts.id,
		code:    "timeout",
		message: fmt.Sprintf("Command timed out after %d ms", opts.timeoutMS),
	})
}

func isSupportedCPSLLanguage(language string) bool {
	return language == cpslLanguageLuau || language == cpslLanguageBash
}

type decodeCPSLEvalResponseOptions struct {
	data      []byte
	requestID int64
}

func decodeCPSLEvalResponse(opts decodeCPSLEvalResponseOptions) (cpslEvalResponse, error) {
	var response cpslEvalResponse
	if err := json.Unmarshal(opts.data, &response); err != nil {
		return cpslEvalResponse{}, fmt.Errorf("decode CPSL response: %w", err)
	}
	if response.ID != opts.requestID {
		return cpslEvalResponse{}, fmt.Errorf("CPSL response id %d did not match request id %d", response.ID, opts.requestID)
	}
	if response.Warnings == nil {
		response.Warnings = []string{}
	}
	if response.CWD == "" {
		response.CWD = cpslWorkerInitialCW
	}
	return response, nil
}
