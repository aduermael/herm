package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

type fakeCPSLEvaluator struct {
	evalFunc func(opts cpslSessionEvalOptions) (string, error)
}

func (f fakeCPSLEvaluator) eval(opts cpslSessionEvalOptions) (string, error) {
	return f.evalFunc(opts)
}

func TestServeCPSLWorkerEvalPreservesID(t *testing.T) {
	request := `{"id":7,"op":"eval","language":"luau","input":"print('ok')","timeout_ms":1000}` + "\n"
	var stdout bytes.Buffer

	err := serveCPSLWorker(serveCPSLWorkerOptions{
		evaluator: fakeCPSLEvaluator{evalFunc: func(opts cpslSessionEvalOptions) (string, error) {
			var req struct {
				Language  string `json:"language"`
				Input     string `json:"input"`
				TimeoutMS int    `json:"timeout_ms"`
			}
			if err := json.Unmarshal([]byte(opts.requestJSON), &req); err != nil {
				t.Fatalf("eval request JSON: %v", err)
			}
			if req.Language != "luau" || req.Input != "print('ok')" || req.TimeoutMS != 1000 {
				t.Fatalf("eval request = %#v", req)
			}
			return `{"ok":true,"stdout":"ok\n","stderr":"","exit_code":0,"error":null,"warnings":[],"cwd":"/workdir"}`, nil
		}},
		session: 1,
		stdin:   strings.NewReader(request),
		stdout:  &stdout,
		stderr:  ioDiscard{},
	})
	if err != nil {
		t.Fatalf("serveCPSLWorker: %v", err)
	}

	response := decodeWorkerTestResponse(t, stdout.Bytes())
	if response.ID != 7 {
		t.Fatalf("response ID = %d, want 7", response.ID)
	}
	if !response.OK || response.Stdout != "ok\n" {
		t.Fatalf("response = %#v", response)
	}
}

func TestServeCPSLWorkerMalformedAndUnsupportedRequests(t *testing.T) {
	input := strings.Join([]string{
		`not-json`,
		`{"id":2,"op":"stat","language":"bash","input":"pwd","timeout_ms":1000}`,
		`{"id":3,"op":"eval","language":"python","input":"pwd","timeout_ms":1000}`,
		"",
	}, "\n")
	var stdout bytes.Buffer

	err := serveCPSLWorker(serveCPSLWorkerOptions{
		evaluator: fakeCPSLEvaluator{evalFunc: func(cpslSessionEvalOptions) (string, error) {
			t.Fatal("eval should not be called")
			return "", nil
		}},
		stdin:  strings.NewReader(input),
		stdout: &stdout,
		stderr: ioDiscard{},
	})
	if err != nil {
		t.Fatalf("serveCPSLWorker: %v", err)
	}

	responses := decodeWorkerTestResponses(t, stdout.Bytes())
	if len(responses) != 3 {
		t.Fatalf("got %d responses, want 3", len(responses))
	}
	if responses[0].ID != 0 || responses[0].Error.Code != "invalid_request" {
		t.Fatalf("malformed response = %#v", responses[0])
	}
	if responses[1].ID != 2 || responses[1].Error.Code != "invalid_request" {
		t.Fatalf("unsupported op response = %#v", responses[1])
	}
	if responses[2].ID != 3 || responses[2].Error.Code != "unsupported_language" {
		t.Fatalf("unsupported language response = %#v", responses[2])
	}
}

func TestServeCPSLWorkerTimeoutRespondsAndTerminates(t *testing.T) {
	request := `{"id":9,"op":"eval","language":"bash","input":"sleep","timeout_ms":5}` + "\n"
	var stdout bytes.Buffer

	err := serveCPSLWorker(serveCPSLWorkerOptions{
		evaluator: fakeCPSLEvaluator{evalFunc: func(cpslSessionEvalOptions) (string, error) {
			time.Sleep(100 * time.Millisecond)
			return `{"ok":true,"stdout":"","stderr":"","exit_code":0,"error":null,"warnings":[],"cwd":"/workdir"}`, nil
		}},
		stdin:  strings.NewReader(request),
		stdout: &stdout,
		stderr: ioDiscard{},
	})
	if !errors.Is(err, errCPSLWorkerTerminated) {
		t.Fatalf("serveCPSLWorker err = %v, want termination sentinel", err)
	}

	response := decodeWorkerTestResponse(t, stdout.Bytes())
	if response.ID != 9 || response.OK || response.Error == nil || response.Error.Code != "timeout" {
		t.Fatalf("timeout response = %#v", response)
	}
}

func TestParseCPSLWorkerOptionsRepeatedDomains(t *testing.T) {
	var stderr bytes.Buffer
	opts, err := parseCPSLWorkerOptions(parseCPSLWorkerArgsOptions{
		args: []string{
			"--library", "/tmp/libcpsl.so",
			"--workspace", "/tmp/work",
			"--allow-domain", "example.com",
			"--allow-domain", "api.example.com",
			"--deny-domain", "blocked.example.com",
			"--deny-domain", "blocked-api.example.com",
		},
		stderr: &stderr,
	})
	if err != nil {
		t.Fatalf("parseCPSLWorkerOptions: %v", err)
	}
	if !slices.Equal(opts.allowDomains, []string{"example.com", "api.example.com"}) {
		t.Fatalf("allowDomains = %#v", opts.allowDomains)
	}
	if !slices.Equal(opts.denyDomains, []string{"blocked.example.com", "blocked-api.example.com"}) {
		t.Fatalf("denyDomains = %#v", opts.denyDomains)
	}
}

func TestSetCPSLLibraryDirEnv(t *testing.T) {
	t.Setenv(cpslLibraryDirEnv, "")
	dir := t.TempDir()
	setCPSLLibraryDirEnv(filepath.Join(dir, "libcpsl.so"))
	if got := os.Getenv(cpslLibraryDirEnv); got != dir {
		t.Fatalf("%s = %q, want %q", cpslLibraryDirEnv, got, dir)
	}
}

func TestCPSLSessionConfigJSON(t *testing.T) {
	configJSON, err := cpslSessionConfigJSON(cpslSessionConfigJSONOptions{
		workspace:    "/tmp/work",
		allowDomains: []string{"example.com", "api.example.com"},
		denyDomains:  []string{"deny.example.com", "deny-api.example.com"},
	})
	if err != nil {
		t.Fatal(err)
	}
	var config cpslSessionConfig
	if err := json.Unmarshal([]byte(configJSON), &config); err != nil {
		t.Fatal(err)
	}
	if config.InitialCWD != "/workdir" || config.Language != "luau" {
		t.Fatalf("config = %#v", config)
	}
	if len(config.Mounts) != 1 || config.Mounts[0].Host != "/tmp/work" || config.Mounts[0].VirtualPath != "/workdir" || config.Mounts[0].Mode != "rw" {
		t.Fatalf("mounts = %#v", config.Mounts)
	}
	if !slices.Equal(config.HTTP.AllowDomains, []string{"example.com", "api.example.com"}) {
		t.Fatalf("allow domains = %#v", config.HTTP.AllowDomains)
	}
	if !slices.Equal(config.HTTP.DenyDomains, []string{"deny.example.com", "deny-api.example.com"}) {
		t.Fatalf("deny domains = %#v", config.HTTP.DenyDomains)
	}
	for _, forbidden := range []string{"credentials", "callback", "prompt"} {
		if strings.Contains(configJSON, forbidden) {
			t.Fatalf("config JSON included unsupported http field %q: %s", forbidden, configJSON)
		}
	}
}

func TestCPSLSessionConfigJSONUsesEmptyDomainArrays(t *testing.T) {
	configJSON, err := cpslSessionConfigJSON(cpslSessionConfigJSONOptions{workspace: "/tmp/work"})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(configJSON, `"allow_domains":null`) || strings.Contains(configJSON, `"deny_domains":null`) {
		t.Fatalf("config JSON encoded nil domain list: %s", configJSON)
	}
	if !strings.Contains(configJSON, `"allow_domains":[]`) || !strings.Contains(configJSON, `"deny_domains":[]`) {
		t.Fatalf("config JSON did not encode empty domain arrays: %s", configJSON)
	}
}

func TestValidateCPSLBackendMetadataJSON(t *testing.T) {
	valid := `{"name":"cpsl","abi_version":1,"version":"0.1.0","languages":["luau","bash"],"capabilities":{"mounts":true,"network_policy":true}}`
	if err := validateCPSLBackendMetadataJSON(valid); err != nil {
		t.Fatalf("valid metadata: %v", err)
	}

	tests := []string{
		`{"name":"other","abi_version":1,"languages":["bash"],"capabilities":{"mounts":true,"network_policy":true}}`,
		`{"name":"cpsl","abi_version":2,"languages":["luau","bash"],"capabilities":{"mounts":true,"network_policy":true}}`,
		`{"name":"cpsl","abi_version":1,"languages":["python"],"capabilities":{"mounts":true,"network_policy":true}}`,
		`{"name":"cpsl","abi_version":1,"languages":["luau"],"capabilities":{"mounts":true,"network_policy":true}}`,
		`{"name":"cpsl","abi_version":1,"languages":["luau","bash"],"capabilities":{"mounts":false,"network_policy":true}}`,
		`not-json`,
	}
	for _, tt := range tests {
		if err := validateCPSLBackendMetadataJSON(tt); err == nil {
			t.Fatalf("metadata %s returned nil error", tt)
		}
	}
}

func decodeWorkerTestResponse(t *testing.T, data []byte) cpslEvalResponse {
	t.Helper()
	responses := decodeWorkerTestResponses(t, data)
	if len(responses) != 1 {
		t.Fatalf("got %d responses, want 1", len(responses))
	}
	return responses[0]
}

func decodeWorkerTestResponses(t *testing.T, data []byte) []cpslEvalResponse {
	t.Helper()
	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	var responses []cpslEvalResponse
	for _, line := range lines {
		if line == "" {
			continue
		}
		var response cpslEvalResponse
		if err := json.Unmarshal([]byte(line), &response); err != nil {
			t.Fatalf("decode response %q: %v", line, err)
		}
		responses = append(responses, response)
	}
	return responses
}

type ioDiscard struct{}

func (ioDiscard) Write(p []byte) (int, error) { return len(p), nil }
