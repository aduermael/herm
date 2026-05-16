package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRoutingSummaryEmptyDefaultProviderModelAndFallbackStages(t *testing.T) {
	empty := strings.Join(routingSummaryRows(nil), "\n")
	expectRowsContainAll(t, empty,
		"Routing is global.",
		"No routing policy is configured. Herm uses eligible configured deployments automatically.",
	)

	app := phase9RoutingApp()
	rows := strings.Join(app.buildConfigRows(), "\n")
	expectRowsContainAll(t, rows,
		"Model routes override provider routes; provider routes override the default route.",
		"Overrides do not cascade to default.",
		"Default: stage 1 tries openai-direct (weight 70) and openrouter (weight 30), retries 2; stage 2 tries openrouter (weight 100), retries 1.",
		"Provider openai: stage 1 tries openai-direct (weight 100), retries 1.",
		"Model openai/gpt-4.1-2025-04-14: stage 1 tries openrouter (weight 100), retries 1.",
	)
}

func TestRoutingSummaryDisplaysRelativeWeights(t *testing.T) {
	summary := routingStagesSummary([]RoutingStage{{
		Deployments: []DeploymentChoice{
			{DeploymentID: "openai-direct", Weight: 1},
			{DeploymentID: "openrouter", Weight: 1},
		},
	}})
	if strings.Contains(summary, "1%") {
		t.Fatalf("routing summary should not render relative weights as percentages: %q", summary)
	}
	expectRowsContainAll(t, summary, "openai-direct (weight 1)", "openrouter (weight 1)")
}

func TestBuildConfigRowsRoutingRemovesPrimaryRouteControls(t *testing.T) {
	rows := strings.Join(phase9RoutingApp().buildConfigRows(), "\n")
	expectRowsContainAll(t, rows, "routing JSON", "Ctrl+E=edit global JSON")
	expectRowsNotContainAny(t, rows,
		"Route syntax:",
		"Default Route:",
		"OpenAI Route:",
		"Model Route ",
	)
}

func TestRoutingJSONPreviewTruncationAndEmptyObject(t *testing.T) {
	empty := routingJSONPreviewRows(routingJSONPreviewRowsOptions{policy: nil, maxLines: routingJSONPreviewMaxLines})
	if got := strings.Join(empty, "\n"); got != "{}" {
		t.Fatalf("empty routing preview = %q, want {}", got)
	}

	app := phase9RoutingApp()
	app.cfgDraft.Routing.Models = map[string][]RoutingStage{}
	for _, modelID := range []string{
		"anthropic/claude-haiku-4-5",
		"anthropic/claude-opus-4-6",
		"anthropic/claude-sonnet-4-6",
		"google/gemini-2.5-flash",
		"google/gemini-2.5-pro",
		"openai/gpt-4.1-2025-04-14",
		"openai/gpt-4.1-mini-2025-04-14",
		"xai/grok-4-1-fast-reasoning",
		"z-ai/glm-4.5-air:free",
	} {
		app.cfgDraft.Routing.Models[modelID] = []RoutingStage{{
			Deployments: []DeploymentChoice{{DeploymentID: "openrouter", Weight: 100}},
			Retries:     1,
		}}
	}

	rows := routingJSONPreviewRows(routingJSONPreviewRowsOptions{policy: app.cfgDraft.Routing, maxLines: 8})
	if len(rows) != 8 {
		t.Fatalf("truncated preview row count = %d, want 8: %#v", len(rows), rows)
	}
	last := rows[len(rows)-1]
	if !strings.Contains(last, "...") || !strings.Contains(last, "more routing JSON lines") {
		t.Fatalf("truncated preview should end with remaining-line indicator, got %q", last)
	}
}

func TestRoutingDiagnosticsRemainVisibleAndCapped(t *testing.T) {
	app := &App{
		cfgTab: 1,
		cfgDraft: Config{Routing: &RoutingPolicy{Default: []RoutingStage{{
			Deployments: []DeploymentChoice{
				{DeploymentID: "not-a-deployment", Weight: 0},
				{DeploymentID: "", Weight: 0},
				{DeploymentID: "openai-direct", Weight: 100},
			},
			Retries: -1,
		}}}},
	}

	rows := strings.Join(app.buildConfigRows(), "\n")
	expectRowsContainAll(t, rows,
		"routing.default[0].deployments[0].deployment_id",
		"routing.default[0].deployments[0].weight",
		"more routing diagnostics",
	)
}

func TestRoutingEditorCtrlEReloadsValidGlobalJSON(t *testing.T) {
	t.Setenv("HOME", t.TempDir())

	var editorPath string
	original := Config{
		ActiveModel: "openai/gpt-4.1-2025-04-14",
		Routing: &RoutingPolicy{Default: []RoutingStage{{
			Deployments: []DeploymentChoice{{DeploymentID: "openai-direct", Weight: 100}},
			Retries:     1,
		}}},
	}
	if err := saveConfig(original); err != nil {
		t.Fatalf("saveConfig: %v", err)
	}
	app := &App{
		headless:     true,
		cfgTab:       1,
		globalConfig: original,
		cfgDraft:     original,
		configJSONEditor: func(path string) error {
			editorPath = path
			return os.WriteFile(path, []byte(`{
  "config_version": 2,
  "active_model": "anthropic/claude-haiku-4-5",
  "routing": {
    "default": [
      {
        "deployments": [
          { "deployment_id": "openrouter", "weight": 100 }
        ],
        "retries": 3
      }
    ]
  }
}`), 0o644)
		},
	}

	app.handleConfigByte(handleConfigByteOptions{ch: 0x05})

	if editorPath != filepath.Join(os.Getenv("HOME"), configDir, configFile) {
		t.Fatalf("editor path = %q, want global config path", editorPath)
	}
	if app.cfgDraft.ActiveModel != "anthropic/claude-haiku-4-5" {
		t.Fatalf("cfgDraft ActiveModel = %q, want reloaded edit", app.cfgDraft.ActiveModel)
	}
	if app.cfgDraft.Routing == nil || len(app.cfgDraft.Routing.Default) != 1 || app.cfgDraft.Routing.Default[0].Retries != 3 {
		t.Fatalf("cfgDraft routing was not reloaded: %+v", app.cfgDraft.Routing)
	}
	if len(app.messages) == 0 || app.messages[len(app.messages)-1].kind != msgSuccess {
		t.Fatalf("successful editor reload should append success message, got %+v", app.messages)
	}
}

func TestRoutingEditorRefusesUnsavedDrafts(t *testing.T) {
	t.Setenv("HOME", t.TempDir())

	saved := Config{ActiveModel: "openai/gpt-4.1-2025-04-14"}
	if err := saveConfig(saved); err != nil {
		t.Fatalf("saveConfig: %v", err)
	}
	called := false
	app := &App{
		headless:     true,
		cfgTab:       1,
		globalConfig: saved,
		cfgDraft:     Config{ActiveModel: "anthropic/claude-haiku-4-5"},
		configJSONEditor: func(string) error {
			called = true
			return nil
		},
	}

	app.handleConfigByte(handleConfigByteOptions{ch: 0x05})

	if called {
		t.Fatal("editor should not open while global draft has unsaved changes")
	}
	if app.cfgDraft.ActiveModel != "anthropic/claude-haiku-4-5" || app.globalConfig.ActiveModel != saved.ActiveModel {
		t.Fatalf("unsaved draft refusal changed memory: draft=%+v global=%+v", app.cfgDraft, app.globalConfig)
	}
	if len(app.messages) == 0 || app.messages[len(app.messages)-1].kind != msgError || !strings.Contains(app.messages[len(app.messages)-1].content, "Save or discard") {
		t.Fatalf("unsaved draft refusal should append deliberate error, got %+v", app.messages)
	}
}

func TestRoutingEditorFailureAndMalformedJSONKeepCurrentDraft(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	errEditor := errors.New("editor failed")
	original := Config{ActiveModel: "openai/gpt-4.1-2025-04-14"}
	if err := saveConfig(original); err != nil {
		t.Fatalf("saveConfig: %v", err)
	}
	app := &App{
		headless:         true,
		cfgTab:           1,
		cfgDraft:         original,
		configJSONEditor: func(string) error { return errEditor },
		cfgProjectDraft:  ProjectConfig{Personality: "project"},
		projectConfig:    ProjectConfig{Personality: "project"},
		globalConfig:     original,
		config:           mergeConfigs(mergeConfigsOptions{global: original, project: ProjectConfig{Personality: "project"}}),
	}

	app.handleConfigByte(handleConfigByteOptions{ch: 0x05})

	if app.cfgDraft.ActiveModel != original.ActiveModel {
		t.Fatalf("editor failure changed draft to %+v", app.cfgDraft)
	}
	if app.globalConfig.ActiveModel != original.ActiveModel || app.config.ActiveModel != original.ActiveModel {
		t.Fatalf("editor failure changed active memory: global=%+v effective=%+v", app.globalConfig, app.config)
	}
	if len(app.messages) == 0 || app.messages[len(app.messages)-1].kind != msgError {
		t.Fatalf("editor failure should append error message, got %+v", app.messages)
	}

	t.Setenv("HOME", t.TempDir())
	if err := saveConfig(original); err != nil {
		t.Fatalf("saveConfig: %v", err)
	}
	editorRuns := 0
	app = &App{
		headless:     true,
		cfgTab:       1,
		cfgDraft:     original,
		globalConfig: original,
		config:       original,
		configJSONEditor: func(path string) error {
			editorRuns++
			if editorRuns == 2 {
				data, err := os.ReadFile(path)
				if err != nil {
					return err
				}
				if string(data) != `{"routing":` {
					t.Fatalf("second editor open should preserve malformed JSON for repair, got %q", data)
				}
				return errEditor
			}
			return os.WriteFile(path, []byte(`{"routing":`), 0o644)
		},
	}

	app.handleConfigByte(handleConfigByteOptions{ch: 0x05})

	if app.cfgDraft.ActiveModel != original.ActiveModel {
		t.Fatalf("malformed JSON changed draft to %+v", app.cfgDraft)
	}
	if app.globalConfig.ActiveModel != original.ActiveModel || app.config.ActiveModel != original.ActiveModel {
		t.Fatalf("malformed JSON changed active memory: global=%+v effective=%+v", app.globalConfig, app.config)
	}
	if len(app.messages) == 0 || app.messages[len(app.messages)-1].kind != msgError || !strings.Contains(app.messages[len(app.messages)-1].content, "invalid") {
		t.Fatalf("malformed JSON should append invalid JSON error, got %+v", app.messages)
	}

	app.handleConfigByte(handleConfigByteOptions{ch: 0x05})
}
