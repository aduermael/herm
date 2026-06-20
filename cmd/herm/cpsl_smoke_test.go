package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"sync"
	"testing"
)

type cpslSmokeLLMStep struct {
	script string
	text   string
}

type cpslSmokeLLMServer struct {
	server *httptest.Server

	mu     sync.Mutex
	steps  []cpslSmokeLLMStep
	bodies []string
}

func newCPSLSmokeLLMServer(t *testing.T) *cpslSmokeLLMServer {
	t.Helper()
	fake := &cpslSmokeLLMServer{}
	fake.server = httptest.NewServer(http.HandlerFunc(fake.handle))
	t.Cleanup(fake.server.Close)
	return fake
}

func (s *cpslSmokeLLMServer) URL() string {
	return s.server.URL
}

func (s *cpslSmokeLLMServer) enqueue(steps ...cpslSmokeLLMStep) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	start := len(s.bodies)
	s.steps = append(s.steps, steps...)
	return start
}

func (s *cpslSmokeLLMServer) bodiesSince(start int) []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string(nil), s.bodies[start:]...)
}

func (s *cpslSmokeLLMServer) handle(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/responses" {
		http.Error(w, "unexpected path", http.StatusNotFound)
		return
	}
	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	s.mu.Lock()
	s.bodies = append(s.bodies, string(body))
	if len(s.steps) == 0 {
		s.mu.Unlock()
		http.Error(w, "no scripted response queued", http.StatusInternalServerError)
		return
	}
	step := s.steps[0]
	s.steps = s.steps[1:]
	idx := len(s.bodies)
	s.mu.Unlock()

	w.Header().Set("Content-Type", "text/event-stream")
	if step.script != "" {
		writeCPSLSmokeToolCall(w, idx, step.script)
		return
	}
	writeCPSLSmokeText(w, idx, step.text)
}

func writeCPSLSmokeToolCall(w io.Writer, idx int, script string) {
	callID := fmt.Sprintf("call_cpsl_%d", idx)
	args, _ := json.Marshal(map[string]string{"script": script})
	item := map[string]any{
		"type":      "function_call",
		"call_id":   callID,
		"name":      toolLocalSandboxExec,
		"arguments": string(args),
	}
	writeCPSLSmokeSSE(w, map[string]any{
		"type":         "response.output_item.added",
		"output_index": 0,
		"item":         item,
	})
	writeCPSLSmokeSSE(w, map[string]any{
		"type":         "response.function_call_arguments.done",
		"output_index": 0,
		"name":         toolLocalSandboxExec,
		"arguments":    string(args),
	})
	writeCPSLSmokeSSE(w, map[string]any{
		"type": "response.completed",
		"response": map[string]any{
			"id":     fmt.Sprintf("resp_cpsl_%d", idx),
			"model":  "gpt-4.1",
			"status": "completed",
			"output": []any{item},
			"usage":  map[string]any{"input_tokens": 10, "output_tokens": 3},
		},
	})
}

func writeCPSLSmokeText(w io.Writer, idx int, text string) {
	writeCPSLSmokeSSE(w, map[string]any{
		"type":  "response.output_text.delta",
		"delta": text,
	})
	writeCPSLSmokeSSE(w, map[string]any{
		"type": "response.completed",
		"response": map[string]any{
			"id":     fmt.Sprintf("resp_cpsl_%d", idx),
			"model":  "gpt-4.1",
			"status": "completed",
			"output": []any{
				map[string]any{
					"type": "message",
					"role": "assistant",
					"content": []any{
						map[string]any{"type": "output_text", "text": text},
					},
				},
			},
			"usage": map[string]any{"input_tokens": 10, "output_tokens": 3},
		},
	})
}

func writeCPSLSmokeSSE(w io.Writer, value any) {
	data, _ := json.Marshal(value)
	fmt.Fprintf(w, "data: %s\n\n", data)
}

func TestCPSLHeadlessSmoke(t *testing.T) {
	libraryPath := strings.TrimSpace(os.Getenv("CPSL_FFI_LIB"))
	if libraryPath == "" {
		t.Skip("set CPSL_FFI_LIB to a built CPSL dynamic library to run the CPSL smoke")
	}
	libraryPath, err := filepath.Abs(libraryPath)
	if err != nil {
		t.Fatalf("resolve CPSL_FFI_LIB: %v", err)
	}
	if info, err := os.Stat(libraryPath); err != nil || info.IsDir() {
		t.Fatalf("CPSL_FFI_LIB must point to a dynamic library file, got %q", libraryPath)
	}

	hermBin := buildHermSmokeBinary(t)
	llm := newCPSLSmokeLLMServer(t)
	httpTarget, httpTargetURL := newCPSLSmokeHTTPServer(t, http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = io.WriteString(w, "phase8-network-ok")
	}))
	t.Cleanup(httpTarget.Close)

	t.Run("native luau files and data", func(t *testing.T) {
		workspace := newCPSLSmokeWorkspace(t)
		script := strings.Join([]string{
			`print("/workdir")`,
			`print(json.encode(fs.list("/workdir")))`,
			`print(fs.read("/workdir/phase8-input.md"))`,
			`print(fs.read("/workdir/data.json"))`,
			`print(fs.read("/workdir/data.csv"))`,
			`fs.write("/workdir/phase8-report.md", "# Phase 8 Report\nstatus: cpsl-smoke\n")`,
			`fs.write("/workdir/phase8-output.json", "{\"generated\":true,\"kind\":\"json\"}\n")`,
			`fs.write("/workdir/phase8-output.csv", "name,value\nphase8,ok\n")`,
		}, "\n")
		start := llm.enqueue(
			cpslSmokeLLMStep{script: script},
			cpslSmokeLLMStep{text: "phase8 file smoke complete"},
		)

		stdout, stderr := runHermCPSLSmoke(t, runHermCPSLSmokeOptions{
			hermBin:     hermBin,
			libraryPath: libraryPath,
			workspace:   workspace,
			llmURL:      llm.URL(),
			prompt:      "Run the CPSL phase 8 file smoke.",
		})
		if !strings.Contains(stdout, "phase8 file smoke complete") {
			t.Fatalf("stdout = %q\nstderr = %q", stdout, stderr)
		}
		assertFileContains(t, filepath.Join(workspace, "phase8-report.md"), "cpsl-smoke")
		assertFileContains(t, filepath.Join(workspace, "phase8-output.json"), `"generated":true`)
		assertFileContains(t, filepath.Join(workspace, "phase8-output.csv"), "phase8,ok")

		requests := llm.bodiesSince(start)
		requireSmokeRequestToolContract(t, requests)
		requireSmokeRequestContains(t, requests, "/workdir")
		requireSmokeRequestContains(t, requests, "phase8-input.md")
		requireSmokeRequestContains(t, requests, "phase8 fixture")
	})

	t.Run("network denied by default", func(t *testing.T) {
		workspace := newCPSLSmokeWorkspace(t)
		start := llm.enqueue(
			cpslSmokeLLMStep{script: fmt.Sprintf("return http.get(%q)", httpTargetURL)},
			cpslSmokeLLMStep{text: "phase8 network deny smoke complete"},
		)

		stdout, stderr := runHermCPSLSmoke(t, runHermCPSLSmokeOptions{
			hermBin:     hermBin,
			libraryPath: libraryPath,
			workspace:   workspace,
			llmURL:      llm.URL(),
			prompt:      "Verify default CPSL network denial.",
		})
		if !strings.Contains(stdout, "phase8 network deny smoke complete") {
			t.Fatalf("stdout = %q\nstderr = %q", stdout, stderr)
		}

		requests := llm.bodiesSince(start)
		requireSmokeRequestContains(t, requests, "sandbox_denied")
		requireSmokeRequestContains(t, requests, "Network access is denied by policy")
	})

	t.Run("network allowed by domain", func(t *testing.T) {
		workspace := newCPSLSmokeWorkspace(t)
		start := llm.enqueue(
			cpslSmokeLLMStep{script: fmt.Sprintf("local resp = http.get(%q)\nprint(resp.body)", httpTargetURL)},
			cpslSmokeLLMStep{text: "phase8 network allow smoke complete"},
		)

		stdout, stderr := runHermCPSLSmoke(t, runHermCPSLSmokeOptions{
			hermBin:      hermBin,
			libraryPath:  libraryPath,
			workspace:    workspace,
			llmURL:       llm.URL(),
			allowDomains: []string{"localhost"},
			prompt:       "Verify CPSL network allow-domain behavior.",
		})
		if !strings.Contains(stdout, "phase8 network allow smoke complete") {
			t.Fatalf("stdout = %q\nstderr = %q", stdout, stderr)
		}

		requests := llm.bodiesSince(start)
		requireSmokeRequestContains(t, requests, "phase8-network-ok")
	})
}

func buildHermSmokeBinary(t *testing.T) string {
	t.Helper()
	bin := filepath.Join(t.TempDir(), "herm-smoke")
	if os.PathSeparator == '\\' {
		bin += ".exe"
	}
	cmd := exec.Command("go", "build", "-o", bin, ".")
	cmd.Dir = hermSmokePackageDir(t)
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("go build herm smoke binary: %v\n%s", err, output)
	}
	return bin
}

func newCPSLSmokeHTTPServer(t *testing.T, handler http.Handler) (*httptest.Server, string) {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen for smoke HTTP server: %v", err)
	}
	server := httptest.NewUnstartedServer(handler)
	server.Listener = listener
	server.Start()

	addr, ok := listener.Addr().(*net.TCPAddr)
	if !ok {
		t.Fatalf("unexpected listener address %T", listener.Addr())
	}
	return server, "http://localhost:" + strconv.Itoa(addr.Port)
}

func hermSmokePackageDir(t *testing.T) string {
	t.Helper()
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("locate smoke test source")
	}
	return filepath.Dir(file)
}

func newCPSLSmokeWorkspace(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	writeSmokeFile(t, filepath.Join(dir, "phase8-input.md"), "# Phase 8\nphase8 fixture\n")
	writeSmokeFile(t, filepath.Join(dir, "data.json"), "{\"items\":[\"alpha\",\"beta\"]}\n")
	writeSmokeFile(t, filepath.Join(dir, "data.csv"), "name,value\nalpha,1\nbeta,2\n")
	return dir
}

func writeSmokeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}

type runHermCPSLSmokeOptions struct {
	hermBin      string
	libraryPath  string
	workspace    string
	llmURL       string
	allowDomains []string
	prompt       string
}

func runHermCPSLSmoke(t *testing.T, opts runHermCPSLSmokeOptions) (string, string) {
	t.Helper()
	overrides := map[string]any{
		"openai_api_key":      "sk-cpsl-smoke",
		"active_model":        "openai/gpt-4.1-2025-04-14",
		"exploration_model":   "openai/gpt-4.1-mini-2025-04-14",
		"max_tool_iterations": 8,
		"deployments": map[string]any{
			"openai-direct": map[string]any{
				"api_key":  "sk-cpsl-smoke",
				"base_url": opts.llmURL,
			},
		},
	}
	overrideJSON, err := json.Marshal(overrides)
	if err != nil {
		t.Fatalf("marshal config overrides: %v", err)
	}

	args := []string{"--cpsl", opts.libraryPath}
	for _, domain := range opts.allowDomains {
		args = append(args, "--allow-domain", domain)
	}
	args = append(args, "--config-overrides", string(overrideJSON), "-p", opts.prompt)

	cmd := exec.Command(opts.hermBin, args...)
	cmd.Dir = opts.workspace
	home := filepath.Join(t.TempDir(), "home")
	emptyPath := filepath.Join(t.TempDir(), "path")
	if err := os.MkdirAll(home, 0o755); err != nil {
		t.Fatalf("create home: %v", err)
	}
	if err := os.MkdirAll(emptyPath, 0o755); err != nil {
		t.Fatalf("create empty path: %v", err)
	}
	cmd.Env = append(os.Environ(),
		"HOME="+home,
		"LANGDAG_MODEL_CATALOG_REFRESH=off",
		"PATH="+emptyPath,
	)

	stdout, stderr, err := runSmokeCommand(cmd)
	if err != nil {
		t.Fatalf("herm CPSL smoke failed: %v\nstdout:\n%s\nstderr:\n%s", err, stdout, stderr)
	}
	return stdout, stderr
}

func runSmokeCommand(cmd *exec.Cmd) (string, string, error) {
	var stdout, stderr strings.Builder
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	return stdout.String(), stderr.String(), err
}

func assertFileContains(t *testing.T, path, want string) {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	if !strings.Contains(string(data), want) {
		t.Fatalf("%s = %q, want it to contain %q", path, data, want)
	}
}

func requireSmokeRequestContains(t *testing.T, requests []string, want string) {
	t.Helper()
	for _, request := range requests {
		if strings.Contains(request, want) {
			return
		}
	}
	t.Fatalf("no LLM request contained %q; requests:\n%s", want, strings.Join(requests, "\n--- request ---\n"))
}

func requireSmokeRequestToolContract(t *testing.T, requests []string) {
	t.Helper()
	for _, request := range requests {
		var body struct {
			Tools []struct {
				Name string `json:"name"`
			} `json:"tools"`
		}
		if err := json.Unmarshal([]byte(request), &body); err != nil || len(body.Tools) == 0 {
			continue
		}

		var names []string
		for _, tool := range body.Tools {
			names = append(names, tool.Name)
		}
		if len(names) < 1 || names[0] != toolLocalSandboxExec {
			t.Fatalf("CPSL request tools = %v, want %s first", names, toolLocalSandboxExec)
		}
		for _, forbidden := range []string{toolLocalSandboxExecBash, toolBash, "luau"} {
			if slices.Contains(names, forbidden) {
				t.Fatalf("CPSL request tools = %v, should not include %q", names, forbidden)
			}
		}
		return
	}
	t.Fatalf("no LLM request contained tool definitions; requests:\n%s", strings.Join(requests, "\n--- request ---\n"))
}
