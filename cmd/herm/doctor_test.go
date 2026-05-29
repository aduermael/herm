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
			name: "no keys",
			config: Config{
				AnthropicAPIKey:  "",
				OpenAIAPIKey:     "",
				GrokAPIKey:       "",
				OpenRouterAPIKey: "",
				GeminiAPIKey:     "",
			},
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

func TestDoctorRuntimeChecks(t *testing.T) {
	t.Run("container client is uninitialized", func(t *testing.T) {
		// Leave a.container as nil to test the new defensive path
		app := &App{container: nil}

		checks := app.doctorRuntimeChecks()

		if len(checks) == 0 || checks[0].status != doctorStatusFail {
			t.Errorf("expected fail status when container client is nil, got %v", checks)
		}
		if !strings.Contains(checks[0].detail, "Unreachable") {
			t.Errorf("expected detail to mention Unreachable, got %q", checks[0].detail)
		}
	})

	t.Run("container client exists and docker daemon succeeds", func(t *testing.T) {
		// Initialize container using your existing NewContainerClient constructor,
		// but swap or mock the underlying check mechanism if required.
		// Assuming NewContainerClient gives us a working instance:
		app := &App{
			container: NewContainerClient(ContainerConfig{Image: "test-image"}),
		}

		// Mock the global command overrides specifically for the live daemon check
		origDockerCmd := dockerCommand
		origLookPath := lookPath
		defer func() {
			dockerCommand = origDockerCmd
			lookPath = origLookPath
		}()

		lookPath = func(path string) (string, error) { return "/usr/bin/docker", nil }
		dockerCommand = func(ctx context.Context, name string, arg ...string) *exec.Cmd {
			return exec.CommandContext(ctx, "true") // command succeeds
		}

		checks := app.doctorRuntimeChecks()
		if len(checks) == 0 || checks[0].status != doctorStatusOK {
			t.Errorf("expected success status when daemon is reachable, got %v", checks)
		}
	})

	t.Run("container client exists but docker daemon fails", func(t *testing.T) {
		app := &App{
			container: NewContainerClient(ContainerConfig{Image: "test-image"}),
		}

		origDockerCmd := dockerCommand
		origLookPath := lookPath
		defer func() {
			dockerCommand = origDockerCmd
			lookPath = origLookPath
		}()

		lookPath = func(path string) (string, error) { return "/usr/bin/docker", nil }
		dockerCommand = func(ctx context.Context, name string, arg ...string) *exec.Cmd {
			return exec.CommandContext(ctx, "false") // command fails
		}

		checks := app.doctorRuntimeChecks()
		if len(checks) == 0 || checks[0].status != doctorStatusFail {
			t.Errorf("expected failure status when daemon check fails, got %v", checks)
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
