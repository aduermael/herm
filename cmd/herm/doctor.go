// Package main implements the doctor command to diagnose the local environment.
package main

import (
	"context"
	"errors"
	"fmt"
	"os/exec"
	"strings"
	"time"
)

type doctorStatus string

// Doctor check statuses are intentionally small string values because they are
// rendered directly in the human-readable report.
const (
	doctorStatusOK   doctorStatus = "ok"
	doctorStatusWarn doctorStatus = "warn"
	doctorStatusFail doctorStatus = "fail"
)

// doctorCheck is one individual diagnostic result within a report section.
// Detail explains what was observed; Fix is optional user-facing remediation.
type doctorCheck struct {
	name   string
	detail string
	fix    string
	status doctorStatus
}

// doctorSection groups related checks so the rendered output is easier to read.
type doctorSection struct {
	Name   string
	Checks []doctorCheck
}

// doctorReport is the complete output of /doctor before it is rendered to chat.
// Summary is calculated from all checks after sections are assembled.
type doctorReport struct {
	Summary  string
	Sections []doctorSection
}

// handleDoctorCommand runs the diagnostics, appends the formatted report to the
// chat, and forces a render so the user sees the result immediately.
func (a *App) handleDoctorCommand() {
	report := a.runDoctorReport()
	a.messages = append(a.messages, chatMessage{kind: msgAssistant, content: report.textString()})
	a.render()
}

// runDoctorReport executes each diagnostic group and computes the final summary
// from the combined check results.
func (a *App) runDoctorReport() doctorReport {
	report := doctorReport{
		Sections: []doctorSection{
			{Name: "Environment", Checks: doctorEnvironmentChecks()},
			{Name: "API Keys", Checks: a.doctorCheckApiKey()},
			{Name: "Runtime", Checks: a.doctorRuntimeChecks()},
			{Name: "Git Workspace", Checks: doctorGitChecks()},
		},
	}
	report.Summary = getChecksSummaryResults(&report)
	return report
}

// ─── Doctor checks by report section ───

// doctorEnvironmentChecks verifies required local executables are available on
// PATH before Herm tries to use them elsewhere.
func doctorEnvironmentChecks() []doctorCheck {
	checks := []doctorCheck{
		checkExecutable("docker"),
		checkExecutable("git"),
	}
	return checks
}

// doctorCheckApiKey verifies at least one supported LLM provider key is
// configured. Herm can run with any one of these providers.
func (a *App) doctorCheckApiKey() []doctorCheck {
	var checks []doctorCheck
	if a.config.AnthropicAPIKey == "" &&
		a.config.OpenAIAPIKey == "" &&
		a.config.GrokAPIKey == "" &&
		a.config.OpenRouterAPIKey == "" &&
		a.config.GeminiAPIKey == "" {
		return append(checks, doctorCheck{
			name:   "API keys",
			status: doctorStatusFail,
			detail: "no API key found",
			fix:    "Set an API key with /config",
		})
	}
	return append(checks, doctorCheck{
		name:   "API keys",
		status: doctorStatusOK,
		detail: "API key found",
	})
}

// doctorRuntimeChecks validates host runtime dependencies that need active
// services, currently Docker daemon reachability.
func (a *App) doctorRuntimeChecks() []doctorCheck {
	container := a.container
	if container == nil {
		return []doctorCheck{{
			name:   "docker daemon",
			status: doctorStatusFail,
			detail: "Unreachable",
			fix:    "Run docker daemon",
		}}
	}

	if err := container.CheckDocker(); err != nil {
		return []doctorCheck{{
			name:   "docker daemon",
			status: doctorStatusFail,
			detail: err.Error(),
		}}
	}

	return []doctorCheck{{
		name:   "docker daemon",
		status: doctorStatusOK,
		detail: "reachable",
	}}
}

// doctorGitChecks verifies the current working directory is inside a Git
// worktree. Herm still works outside Git, but some workspace features are weaker.
func doctorGitChecks() []doctorCheck {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, "git", "rev-parse", "--is-inside-work-tree")

	if err := cmd.Run(); err != nil {
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return []doctorCheck{{
				name:   "git workspace",
				status: doctorStatusFail,
				detail: "git command timed out",
			}}
		}

		return []doctorCheck{{
			name:   "git workspace",
			status: doctorStatusWarn,
			detail: "not a git repository",
			fix:    "Run 'git init' to leverage full version tracking and hermetic environment branching.",
		}}
	}

	return []doctorCheck{{
		name:   "git workspace",
		status: doctorStatusOK,
		detail: "valid repository",
	}}
}

// checkExecutable returns a single diagnostic for whether a binary is available
// in the current PATH.
func checkExecutable(name string) doctorCheck {
	if _, err := exec.LookPath(name); err != nil {
		return doctorCheck{
			name:   name,
			status: doctorStatusFail,
			detail: "not found on PATH",
			fix:    "Download " + name + " software from their official website",
		}
	}
	return doctorCheck{
		name:   name,
		status: doctorStatusOK,
		detail: "found on PATH",
	}
}

// textString renders the report in the same plain-text style as other Herm chat
// messages, including colored status labels and optional fix hints.
func (r doctorReport) textString() string {
	var b strings.Builder
	b.WriteString("\n")
	b.WriteString(styledSuccess("Herm doctor 💊"))
	b.WriteString("\n")
	b.WriteString("\n")
	b.WriteString("Summary: ")
	switch {
	case strings.Contains(r.Summary, "failed"):
		b.WriteString(styledError(r.Summary))
	case strings.Contains(r.Summary, "warnings"):
		b.WriteString(styledInfo(r.Summary))
	default:
		b.WriteString(styledSuccess(r.Summary))
	}
	b.WriteString("\n")
	for _, section := range r.Sections {
		b.WriteString("\n")
		b.WriteString(section.Name)
		b.WriteString("\n")
		for _, check := range section.Checks {
			b.WriteString("  [")
			b.WriteString(styledDoctorStatus(check.status))
			b.WriteString("] ")
			b.WriteString(check.name)
			if check.detail != "" {
				b.WriteString(": ")
				b.WriteString(check.detail)
			}
			if check.fix != "" {
				b.WriteString(". Fix: ")
				b.WriteString(check.fix)
			}
			b.WriteString("\n")
		}
	}
	return strings.TrimRight(b.String(), "\n")
}

// getChecksSummaryResults counts all check statuses and returns the one-line
// summary displayed at the top of the report.
func getChecksSummaryResults(report *doctorReport) string {
	total, bad, warn := 0, 0, 0
	for _, check := range report.checks() {
		total++
		switch check.status {
		case doctorStatusFail:
			bad++
		case doctorStatusWarn:
			warn++
		}
	}
	switch {
	case bad > 0:
		return fmt.Sprintf("%d checks, %d failed, %d warnings", total, bad, warn)
	case warn > 0:
		return fmt.Sprintf("%d checks, %d warnings", total, warn)
	}
	return fmt.Sprintf("%d checks, all passed", total)
}

// checks flattens every section's checks into one slice for summary counting.
func (r doctorReport) checks() []doctorCheck {
	var count int
	for _, s := range r.Sections {
		count += len(s.Checks)
	}

	out := make([]doctorCheck, 0, count)
	for _, section := range r.Sections {
		out = append(out, section.Checks...)
	}
	return out
}

// styledDoctorStatus maps a diagnostic status to the existing Herm color
// helpers. Unknown statuses are dimmed instead of treated as failures.
func styledDoctorStatus(status doctorStatus) string {
	switch status {
	case doctorStatusOK:
		return styledSuccess(string(status))
	case doctorStatusWarn:
		return styledInfo(string(status))
	case doctorStatusFail:
		return styledError(string(status))
	default:
		return "\033[2m" + string(status) + "\033[0m"
	}
}
