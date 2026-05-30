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

func newCPSLWorkerError(code, message string) *cpslWorkerError {
	return &cpslWorkerError{Code: code, Message: message}
}

func cpslErrorResponse(id int64, code, message string) cpslEvalResponse {
	return cpslEvalResponse{
		ID:       id,
		OK:       false,
		Stdout:   "",
		Stderr:   "",
		ExitCode: nil,
		Error:    &cpslEvalError{Code: code, Message: message},
		Warnings: []string{},
		CWD:      cpslWorkerInitialCW,
	}
}

func cpslTimeoutResponse(id int64, timeoutMS int) cpslEvalResponse {
	return cpslErrorResponse(
		id,
		"timeout",
		fmt.Sprintf("Command timed out after %d ms", timeoutMS),
	)
}

func isSupportedCPSLLanguage(language string) bool {
	return language == cpslLanguageLuau || language == cpslLanguageBash
}

func decodeCPSLEvalResponse(data []byte, requestID int64) (cpslEvalResponse, error) {
	var response cpslEvalResponse
	if err := json.Unmarshal(data, &response); err != nil {
		return cpslEvalResponse{}, fmt.Errorf("decode CPSL response: %w", err)
	}
	if response.ID != requestID {
		return cpslEvalResponse{}, fmt.Errorf("CPSL response id %d did not match request id %d", response.ID, requestID)
	}
	if response.Warnings == nil {
		response.Warnings = []string{}
	}
	if response.CWD == "" {
		response.CWD = cpslWorkerInitialCW
	}
	return response, nil
}
