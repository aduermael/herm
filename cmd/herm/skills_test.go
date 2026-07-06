package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDiscoverSkillsCodexDirectoryFormat(t *testing.T) {
	root := skillRoot{Path: filepath.Join(t.TempDir(), ".agents", "skills"), Scope: skillScopeLocal}
	writeSkillFile(t, filepath.Join(root.Path, "testing", skillDocFileName), `---
name: testing
description: "How to write tests"
metadata:
  short-description: Write focused tests
---

Always write table-driven tests.
`)
	if err := os.WriteFile(filepath.Join(root.Path, "testing", "helper.lua"), []byte("return {}\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	skills, err := discoverSkillsFromRoots([]skillRoot{root})
	if err != nil {
		t.Fatalf("discoverSkillsFromRoots: %v", err)
	}
	if len(skills) != 1 {
		t.Fatalf("got %d skills, want 1", len(skills))
	}
	if skills[0].Name != "testing" {
		t.Errorf("Name = %q, want testing", skills[0].Name)
	}
	if skills[0].Description != "Write focused tests" {
		t.Errorf("Description = %q, want short metadata description", skills[0].Description)
	}
	if skills[0].Path != "/skills/testing/SKILL.md" {
		t.Errorf("Path = %q, want /skills/testing/SKILL.md", skills[0].Path)
	}
	if skills[0].sourceKind != skillSourceDirectory {
		t.Errorf("sourceKind = %v, want directory", skills[0].sourceKind)
	}
}

func TestDiscoverSkillsFlatMarkdownFormat(t *testing.T) {
	root := skillRoot{Path: filepath.Join(t.TempDir(), ".agents", "skills"), Scope: skillScopeLocal}
	writeSkillFile(t, filepath.Join(root.Path, "style.md"), `---
description: |
  Keep the UI quiet and practical.
name: style
---

Body content is not prompt-loaded.
`)

	skills, err := discoverSkillsFromRoots([]skillRoot{root})
	if err != nil {
		t.Fatalf("discoverSkillsFromRoots: %v", err)
	}
	if len(skills) != 1 {
		t.Fatalf("got %d skills, want 1", len(skills))
	}
	if skills[0].Name != "style" {
		t.Errorf("Name = %q, want style", skills[0].Name)
	}
	if skills[0].Description != "Keep the UI quiet and practical." {
		t.Errorf("Description = %q", skills[0].Description)
	}
	if skills[0].Path != "/skills/style/SKILL.md" {
		t.Errorf("Path = %q, want staged SKILL.md path", skills[0].Path)
	}
}

func TestDiscoverSkillsLocalOverridesGlobal(t *testing.T) {
	globalRoot := skillRoot{Path: filepath.Join(t.TempDir(), ".agents", "skills"), Scope: skillScopeGlobal}
	localRoot := skillRoot{Path: filepath.Join(t.TempDir(), ".agents", "skills"), Scope: skillScopeLocal}
	writeSkillFile(t, filepath.Join(globalRoot.Path, "pdf", skillDocFileName), `---
name: pdf
description: Global PDF skill
---
global
`)
	writeSkillFile(t, filepath.Join(localRoot.Path, "pdf", skillDocFileName), `---
name: pdf
description: Local PDF skill
---
local
`)

	skills, err := discoverSkillsFromRoots([]skillRoot{globalRoot, localRoot})
	if err != nil {
		t.Fatalf("discoverSkillsFromRoots: %v", err)
	}
	if len(skills) != 1 {
		t.Fatalf("got %d skills, want 1", len(skills))
	}
	if skills[0].Description != "Local PDF skill" {
		t.Errorf("Description = %q, want local override", skills[0].Description)
	}
	if skills[0].scope != skillScopeLocal {
		t.Errorf("scope = %q, want local", skills[0].scope)
	}
}

func TestDiscoverSkillsIgnoresLegacyHermSkills(t *testing.T) {
	workspace := t.TempDir()
	writeSkillFile(t, filepath.Join(workspace, ".herm", "skills", "legacy.md"), `---
name: legacy
description: legacy
---
legacy
`)

	skills, err := discoverSkills(workspace)
	if err != nil {
		t.Fatalf("discoverSkills: %v", err)
	}
	for _, skill := range skills {
		if skill.Name == "legacy" {
			t.Fatal("discoverSkills loaded .herm/skills, want ignored")
		}
	}
}

func TestPrepareRuntimeSkillsStagesSupportFiles(t *testing.T) {
	workspace := t.TempDir()
	writeSkillFile(t, filepath.Join(workspace, ".agents", "skills", "pdf", skillDocFileName), `---
name: pdf
description: Build PDFs
---
Use helper.lua when useful.
`)
	if err := os.WriteFile(filepath.Join(workspace, ".agents", "skills", "pdf", "helper.lua"), []byte("return true\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	skills, err := prepareRuntimeSkills(prepareRuntimeSkillsOptions{
		workspace: workspace,
		backend:   backendCPSL,
	})
	if err != nil {
		t.Fatalf("prepareRuntimeSkills: %v", err)
	}
	if len(skills) != 1 {
		t.Fatalf("got %d skills, want 1", len(skills))
	}
	stagedSkill := filepath.Join(workspace, ".herm", skillsRuntimeDirName, "pdf", skillDocFileName)
	if _, err := os.Stat(stagedSkill); err != nil {
		t.Fatalf("staged SKILL.md missing: %v", err)
	}
	stagedHelper := filepath.Join(workspace, ".herm", skillsRuntimeDirName, "pdf", "helper.lua")
	if _, err := os.Stat(stagedHelper); err != nil {
		t.Fatalf("staged support file missing: %v", err)
	}
	if skills[0].Path != "/skills/pdf/SKILL.md" {
		t.Errorf("Path = %q, want CPSL /skills path", skills[0].Path)
	}
}

func TestPrepareRuntimeSkillsUsesWorkspacePathForNaked(t *testing.T) {
	workspace := t.TempDir()
	writeSkillFile(t, filepath.Join(workspace, ".agents", "skills", "host.md"), `---
name: host
description: Host skill
---
body
`)

	skills, err := prepareRuntimeSkills(prepareRuntimeSkillsOptions{
		workspace: workspace,
		backend:   backendNaked,
	})
	if err != nil {
		t.Fatalf("prepareRuntimeSkills: %v", err)
	}
	if len(skills) != 1 {
		t.Fatalf("got %d skills, want 1", len(skills))
	}
	if !strings.HasPrefix(skills[0].Path, workspace) {
		t.Errorf("naked skill path = %q, want host workspace path", skills[0].Path)
	}
}

func TestFormatSkillsListShowsNameDescriptionAndPath(t *testing.T) {
	got := formatSkillsList([]Skill{
		{Name: "pdf", Description: "Build PDFs", Path: "/skills/pdf/SKILL.md"},
		{Name: "style", Path: "/skills/style/SKILL.md"},
	})
	for _, want := range []string{
		"Skills",
		"pdf - Build PDFs",
		"/skills/pdf/SKILL.md",
		"style",
		"/skills/style/SKILL.md",
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("formatSkillsList missing %q in:\n%s", want, got)
		}
	}
}

func TestHandleSkillsCommandListsRuntimeSkills(t *testing.T) {
	workspace := t.TempDir()
	writeSkillFile(t, filepath.Join(workspace, ".agents", "skills", "pdf", skillDocFileName), `---
name: pdf
description: Build PDFs
---
Use semantic HTML.
`)

	app := &App{
		headless:     true,
		width:        80,
		backend:      backendCPSL,
		worktreePath: workspace,
	}
	app.handleCommand("/skills")

	if len(app.messages) != 1 {
		t.Fatalf("messages = %d, want 1", len(app.messages))
	}
	msg := app.messages[0]
	if msg.kind != msgInfo {
		t.Fatalf("message kind = %v, want msgInfo", msg.kind)
	}
	for _, want := range []string{"Skills", "pdf - Build PDFs", "/skills/pdf/SKILL.md"} {
		if !strings.Contains(msg.content, want) {
			t.Fatalf("/skills output missing %q in:\n%s", want, msg.content)
		}
	}
	if _, err := os.Stat(filepath.Join(workspace, ".herm", skillsRuntimeDirName, "pdf", skillDocFileName)); err != nil {
		t.Fatalf("/skills did not stage runtime skill: %v", err)
	}
}

func TestBuildSystemPromptListsSkillsLazily(t *testing.T) {
	prompt := buildSystemPrompt(buildSystemPromptOptions{
		tools:          nil,
		serverTools:    nil,
		skills:         []Skill{{Name: "pdf", Description: "Build PDFs", Path: "/skills/pdf/SKILL.md"}},
		workDir:        "/work",
		personality:    "",
		containerImage: "alpine:latest",
		worktreeBranch: "",
		snap:           nil,
	})
	for _, want := range []string{"## Skills", "**pdf**: Build PDFs", "Read: `/skills/pdf/SKILL.md`", "full instructions are not loaded"} {
		if !strings.Contains(prompt, want) {
			t.Errorf("prompt missing %q", want)
		}
	}
	if strings.Contains(prompt, "### pdf") {
		t.Error("prompt should not include full skill content section")
	}
}

func writeSkillFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}
