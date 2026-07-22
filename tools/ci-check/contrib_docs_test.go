// contrib_docs_test.go verifies contributor documentation policies in
// CONTRIBUTING.md: no-commit-plans rule, practical setup/test guidance, coding
// standards, and no plans/ tree in README project structure.
package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// repoRoot returns the herm module root (parent of tools/). Tests in this
// package run with cwd tools/ci-check when invoked as go test .
func repoRoot(t *testing.T) string {
	t.Helper()
	wd, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	// Prefer walking up from cwd until go.mod with module herm.
	dir := wd
	for {
		mod := filepath.Join(dir, "go.mod")
		if b, err := os.ReadFile(mod); err == nil && strings.HasPrefix(string(b), "module herm\n") {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	// Fallback: tools/ci-check -> ../..
	candidate := filepath.Clean(filepath.Join(wd, "..", ".."))
	if b, err := os.ReadFile(filepath.Join(candidate, "go.mod")); err == nil && strings.HasPrefix(string(b), "module herm\n") {
		return candidate
	}
	t.Fatalf("could not find herm module root from %s", wd)
	return ""
}

func readRepoFile(t *testing.T, root, rel string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(root, rel))
	if err != nil {
		t.Fatalf("read %s: %v", rel, err)
	}
	if len(b) == 0 {
		t.Fatalf("%s is empty", rel)
	}
	return string(b)
}

func TestContributingForbidsCommittingPlans(t *testing.T) {
	root := repoRoot(t)
	text := readRepoFile(t, root, "CONTRIBUTING.md")

	if !strings.Contains(text, "## What not to commit") {
		t.Fatal("CONTRIBUTING.md missing \"## What not to commit\" section")
	}
	needles := []string{
		"do not commit",
		"plans/",
		"planning",
	}
	for _, n := range needles {
		if !strings.Contains(strings.ToLower(text), strings.ToLower(n)) {
			t.Errorf("CONTRIBUTING.md missing no-commit plans policy needle %q", n)
		}
	}
	if strings.Contains(text, "Project planning docs") {
		t.Error("CONTRIBUTING.md should not document plans as committed project docs")
	}
	// Guidelines must live in CONTRIBUTING, not a separate root GUIDELINES.md.
	if st, err := os.Stat(filepath.Join(root, "GUIDELINES.md")); err == nil && !st.IsDir() {
		t.Error("GUIDELINES.md should be merged into CONTRIBUTING.md and removed")
	}
}

func TestContributingGuideIsPractical(t *testing.T) {
	root := repoRoot(t)
	text := readRepoFile(t, root, "CONTRIBUTING.md")

	required := []string{
		"git submodule update --init",
		"go build",
		"go test ./...",
		"tools/ci-check",
		"## Coding standards",
		"## Pull requests",
		"plans/",
		"CI-enforced",
	}
	for _, n := range required {
		if !strings.Contains(text, n) {
			t.Errorf("CONTRIBUTING.md missing expected content %q", n)
		}
	}
}

func TestReadmeDoesNotListPlansTree(t *testing.T) {
	root := repoRoot(t)
	text := readRepoFile(t, root, "README.md")

	if strings.Contains(text, "├── plans/") || strings.Contains(text, "Project planning docs") {
		t.Error("README.md still documents plans/ as part of the project tree")
	}
	if strings.Contains(text, "GUIDELINES.md") {
		t.Error("README.md should not list GUIDELINES.md; standards live in CONTRIBUTING.md")
	}
	if st, err := os.Stat(filepath.Join(root, "plans")); err == nil && st.IsDir() {
		t.Error("plans/ directory still exists; it should not be committed")
	}
	if !strings.Contains(text, "CONTRIBUTING.md") {
		t.Error("README.md should point contributors at CONTRIBUTING.md")
	}
}
