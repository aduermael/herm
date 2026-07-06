package main

import (
	"context"
	"net"
	"os/exec"
	"strings"
	"testing"
)

func TestGetChecksSummaryResults(t *testing.T) {
	tests := []struct {
		name     string
		checks   []doctorCheck
		expected string
	}{
		{
			name: "all passed",
			checks: []doctorCheck{
				{status: doctorStatusOK},
				{status: doctorStatusOK},
			},
			expected: "2 checks, all passed",
		},
		{
			name: "some warnings",
			checks: []doctorCheck{
				{status: doctorStatusOK},
				{status: doctorStatusWarn},
			},
			expected: "2 checks, 1 warnings",
		},
		{
			name: "some failures",
			checks: []doctorCheck{
				{status: doctorStatusOK},
				{status: doctorStatusFail},
			},
			expected: "2 checks, 1 failed, 0 warnings",
		},
		{
			name: "failures and warnings",
			checks: []doctorCheck{
				{status: doctorStatusFail},
				{status: doctorStatusWarn},
				{status: doctorStatusOK},
			},
			expected: "3 checks, 1 failed, 1 warnings",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			report := &doctorReport{
				Sections: []doctorSection{
					{Checks: tt.checks},
				},
			}
			got := getChecksSummaryResults(report)
			if got != tt.expected {
				t.Errorf("getChecksSummaryResults() = %q, want %q", got, tt.expected)
			}
		})
	}
}

func TestDoctorCheckApiKey(t *testing.T) {
	tests := []struct {
		name     string
		config   Config
		expected doctorStatus
	}{
		{
			name:     "no configured providers",
			config:   Config{},
			expected: doctorStatusFail,
		},
		{
			name: "anthropic key present",
			config: Config{
				AnthropicAPIKey: "sk-test",
			},
			expected: doctorStatusOK,
		},
		{
			name: "openai key present",
			config: Config{
				OpenAIAPIKey: "sk-test",
			},
			expected: doctorStatusOK,
		},
		{
			name: "openrouter key present",
			config: Config{
				OpenRouterAPIKey: "sk-test",
			},
			expected: doctorStatusOK,
		},
		{
			name: "ollama base url present",
			config: Config{
				Deployments: map[string]DeploymentConfig{
					"ollama-local": {BaseURL: "http://localhost:11434"},
				},
			},
			expected: doctorStatusOK,
		},
		{
			name: "azure deployment config present",
			config: Config{
				Deployments: map[string]DeploymentConfig{
					"openai-azure": {
						APIKey:     "sk-test",
						Endpoint:    "https://example.openai.azure.com",
						APIVersion:  "2024-05-01",
					},
				},
			},
			expected: doctorStatusOK,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			app := &App{config: tt.config}
			checks := app.doctorCheckApiKey()
			if len(checks) == 0 {
				t.Fatal("expected at least one check")
			}
			if checks[0].status != tt.expected {
				t.Errorf("doctorCheckApiKey() status = %q, want %q", checks[0].status, tt.expected)
			}
		})
	}
}

func TestDoctorCheckApiKey_EnvFallback(t *testing.T) {
	t.Setenv("OPENAI_API_KEY", "sk-env")

	app := &App{config: Config{}}
	checks := app.doctorCheckApiKey()
	if len(checks) == 0 {
		t.Fatal("expected at least one check")
	}
	if checks[0].status != doctorStatusOK {
		t.Fatalf("doctorCheckApiKey() status = %q, want %q", checks[0].status, doctorStatusOK)
	}
	if !strings.Contains(checks[0].detail, ProviderOpenAI) {
		t.Fatalf("expected detail to mention configured provider, got %q", checks[0].detail)
	}
}

func TestDoctorRuntimeChecks(t *testing.T) {
	t.Run("container still starting but docker daemon succeeds", func(t *testing.T) {
		app := &App{
			container:          nil,
			containerReady:     false,
			containerStatusText: "starting…",
		}

		origDockerCmd := dockerCommand
		origLookPath := lookPath
		defer func() {
			dockerCommand = origDockerCmd
			lookPath = origLookPath
		}()

		lookPath = func(path string) (string, error) { return "/usr/bin/docker", nil }
		dockerCommand = func(ctx context.Context, name string, arg ...string) *exec.Cmd {
			return exec.CommandContext(ctx, "true")
		}

		checks := app.doctorRuntimeChecks()
		if len(checks) != 2 {
			t.Fatalf("expected startup warning plus docker check, got %v", checks)
		}
		if checks[0].status != doctorStatusWarn || checks[0].name != "container startup" {
			t.Fatalf("expected startup warning first, got %+v", checks[0])
		}
		if checks[1].status != doctorStatusOK || checks[1].name != "docker daemon" {
			t.Fatalf("expected docker daemon success second, got %+v", checks[1])
		}
	})

	t.Run("docker daemon fails even without a container client", func(t *testing.T) {
		app := &App{container: nil}

		origDockerCmd := dockerCommand
		origLookPath := lookPath
		defer func() {
			dockerCommand = origDockerCmd
			lookPath = origLookPath
		}()

		lookPath = func(path string) (string, error) { return "/usr/bin/docker", nil }
		dockerCommand = func(ctx context.Context, name string, arg ...string) *exec.Cmd {
			return exec.CommandContext(ctx, "false")
		}

		checks := app.doctorRuntimeChecks()
		if len(checks) == 0 || checks[len(checks)-1].status != doctorStatusFail {
			t.Fatalf("expected failure status when daemon check fails, got %v", checks)
		}
	})
}

func TestDoctorReport_TextString(t *testing.T) {
	report := doctorReport{
		Summary: "2 checks, 1 failed, 0 warnings",
		Sections: []doctorSection{
			{
				Name: "Test Section",
				Checks: []doctorCheck{
					{name: "Check 1", status: doctorStatusOK, detail: "ok"},
					{name: "Check 2", status: doctorStatusFail, detail: "bad", fix: "fix it"},
				},
			},
		},
	}
	out := report.textString()
	if !strings.Contains(out, "Herm doctor") || !strings.Contains(out, "Test Section") || !strings.Contains(out, "fix it") {
		t.Errorf("output missing expected content: %q", out)
	}
}

type mockConn struct {
	net.Conn
}

func (m *mockConn) Close() error { return nil }
