package main

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestBuildConfigRowsRoutingReadOnlyPreviewContract(t *testing.T) {
	app := routingPreviewApp()

	rows := strings.Join(app.buildConfigRows(), "\n")

	expectRowsContainAll(t, rows,
		"Set custom routing, per provider or model (advanced).",
		"Provider openai: primary openai-direct",
		"Model openai/gpt-4.1-2025-04-14: primary openrouter",
		"Add rule",
	)
	expectRowsNotContainAny(t, rows,
		"Unmatched models use the advanced JSON default route.",
		"Advanced JSON default route is configured.",
		"Delete rule",
		"A=add rule",
		"D=delete rule",
		"Ctrl+E=edit global JSON",
		"Route syntax:",
		"Default Route:",
		"OpenAI Route:",
		"routing JSON",
		`"default": [`,
		`"providers": {`,
		`"models": {`,
		"sk-openai-secret",
		"api_key",
		`"active_model"`,
		`"config_version"`,
	)
}

func TestRoutingJSONPreviewTruncatesLongPolicies(t *testing.T) {
	app := routingPreviewApp()
	app.cfgDraft.Routing.Models = map[string][]RoutingStage{}
	for _, modelID := range []string{
		"openai/gpt-4.1-2025-04-14",
		"openai/gpt-4.1-mini-2025-04-14",
		"anthropic/claude-sonnet-4-6",
		"anthropic/claude-opus-4-6",
		"google/gemini-2.5-pro",
		"google/gemini-2.5-flash",
		"xai/grok-4-1-fast-reasoning",
		"z-ai/glm-4.5-air:free",
	} {
		app.cfgDraft.Routing.Models[modelID] = []RoutingStage{{
			Deployments: []DeploymentChoice{{DeploymentID: "openrouter", Weight: 100}},
			Retries:     1,
		}}
	}

	rows := strings.Join(app.buildConfigRows(), "\n")

	expectRowsContainAll(t, rows,
		"Model anthropic/claude-opus-4-6: primary openrouter",
		"Model openai/gpt-4.1-2025-04-14: primary openrouter",
		"more routing diagnostics",
	)
	expectRowsNotContainAny(t, rows, "more routing JSON lines")
}

func TestRoutingTabFieldsExposeSelectableActions(t *testing.T) {
	app := routingPreviewApp()

	fields := app.routingTabFields()
	got := make([]string, 0, len(fields))
	for _, field := range fields {
		got = append(got, field.label)
	}
	want := []string{"Add rule", "Provider openai", "Model openai/gpt-4.1-2025-04-14"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("routing fields = %+v, want %+v", got, want)
	}
	if fields[0].action == nil || !fields[0].valueless {
		t.Fatalf("Add rule should be a valueless selectable action: %+v", fields[0])
	}
}

func TestProjectConfigBareModelMigrationKeepsOpusOverride(t *testing.T) {
	repoRoot := t.TempDir()
	writeRawProjectConfig(t, repoRoot, `{"active_model":"claude-opus-4-6","exploration_model":"claude-haiku-4-5"}`)

	project := loadProjectConfig(repoRoot)

	if project.ActiveModel != "anthropic/claude-opus-4-6" {
		t.Fatalf("project ActiveModel = %q, want anthropic/claude-opus-4-6", project.ActiveModel)
	}
	if project.ExplorationModel != "anthropic/claude-haiku-4-5" {
		t.Fatalf("project ExplorationModel = %q, want anthropic/claude-haiku-4-5", project.ExplorationModel)
	}
}

func TestResolveActiveModelProjectBareOverrideBeatsGlobalAndSmartDefault(t *testing.T) {
	repoRoot := t.TempDir()
	writeRawProjectConfig(t, repoRoot, `{"active_model":"claude-opus-4-6"}`)

	global := anthropicDeploymentGlobalConfig()
	global.ActiveModel = "anthropic/claude-sonnet-4-6"
	effective := mergeConfigs(mergeConfigsOptions{global: global, project: loadProjectConfig(repoRoot)})

	if effective.ActiveModel != "anthropic/claude-opus-4-6" {
		t.Fatalf("merged ActiveModel = %q, want canonical project override anthropic/claude-opus-4-6", effective.ActiveModel)
	}
	if got := effective.resolveActiveModel(anthropicDeploymentModels()); got != "anthropic/claude-opus-4-6" {
		t.Fatalf("resolveActiveModel = %q, want project override anthropic/claude-opus-4-6", got)
	}
}

func TestStartAgentStartupAndRuntimeUseProjectBareCanonicalModel(t *testing.T) {
	repoRoot := t.TempDir()
	writeRawProjectConfig(t, repoRoot, `{"active_model":"claude-opus-4-6","exploration_model":"claude-haiku-4-5"}`)

	app := &App{
		globalConfig:  anthropicDeploymentGlobalConfig(),
		models:        anthropicDeploymentModels(),
		configReady:   true,
		langdagClient: newTestClient("ok"),
		resultCh:      make(chan any, 64),
	}
	app.projectConfig = loadProjectConfig(repoRoot)
	app.config = mergeConfigs(mergeConfigsOptions{global: app.globalConfig, project: app.projectConfig})
	app.maybeShowInitialModels()
	t.Cleanup(func() {
		if app.agent != nil {
			app.agent.Cancel()
			select {
			case <-app.agent.DoneCh():
			case <-time.After(500 * time.Millisecond):
			}
		}
		if app.agentTicker != nil {
			app.agentTicker.Stop()
		}
	})

	if app.config.ActiveModel != "anthropic/claude-opus-4-6" {
		t.Errorf("effective startup/runtime ActiveModel = %q, want canonical anthropic/claude-opus-4-6", app.config.ActiveModel)
	}
	startupRows := strings.Join(chatMessageContents(app.messages), "\n")
	if !strings.Contains(startupRows, "Model: claude-opus-4-6") {
		t.Fatalf("startup model display did not use project Opus override:\n%s", startupRows)
	}
	if got := app.config.resolveActiveModel(app.models); got != "anthropic/claude-opus-4-6" {
		t.Fatalf("runtime active model = %q, want anthropic/claude-opus-4-6", got)
	}

	app.startAgent("hello")
	if app.agent == nil {
		t.Fatal("startAgent did not create an agent")
	}
	if app.agent.model != "anthropic/claude-opus-4-6" {
		t.Fatalf("startAgent model = %q, want anthropic/claude-opus-4-6", app.agent.model)
	}
	if app.agent.explorationModel != "anthropic/claude-haiku-4-5" {
		t.Fatalf("startAgent exploration model = %q, want anthropic/claude-haiku-4-5", app.agent.explorationModel)
	}
	subAgentTool, ok := app.agent.tools["agent"].(*SubAgentTool)
	if !ok {
		t.Fatal("startAgent did not install sub-agent tool")
	}
	if subAgentTool.mainModel != "anthropic/claude-opus-4-6" {
		t.Fatalf("sub-agent main model = %q, want anthropic/claude-opus-4-6", subAgentTool.mainModel)
	}
	if subAgentTool.explorationModel != "anthropic/claude-haiku-4-5" {
		t.Fatalf("sub-agent exploration model = %q, want anthropic/claude-haiku-4-5", subAgentTool.explorationModel)
	}
}

func routingPreviewApp() *App {
	return &App{
		cfgTab: cfgTabRouting,
		cfgDraft: Config{
			ActiveModel: "openai/gpt-4.1-2025-04-14",
			Deployments: map[string]DeploymentConfig{
				"openai-direct": {APIKey: "sk-openai-secret"},
				"openrouter":    {APIKey: "sk-or"},
			},
			Routing: &RoutingPolicy{
				Default: []RoutingStage{
					{
						Deployments: []DeploymentChoice{
							{DeploymentID: "openai-direct", Weight: 70},
							{DeploymentID: "openrouter", Weight: 30},
						},
						Retries: 2,
					},
					{
						Deployments: []DeploymentChoice{{DeploymentID: "openrouter", Weight: 100}},
						Retries:     1,
					},
				},
				Providers: map[string][]RoutingStage{
					"openai": {{
						Deployments: []DeploymentChoice{{DeploymentID: "openai-direct", Weight: 100}},
						Retries:     1,
					}},
				},
				Models: map[string][]RoutingStage{
					"openai/gpt-4.1-2025-04-14": {{
						Deployments: []DeploymentChoice{{DeploymentID: "openrouter", Weight: 100}},
						Retries:     1,
					}},
				},
			},
		},
		models: []ModelDef{{
			Provider:      ProviderOpenAI,
			OwnerProvider: ProviderOpenAI,
			ID:            "openai/gpt-4.1-2025-04-14",
			CanonicalID:   "openai/gpt-4.1-2025-04-14",
			Deployments: []ModelDeploymentDef{
				{DeploymentID: "openai-direct", NativeModelID: "gpt-4.1-2025-04-14"},
				{DeploymentID: "openrouter", NativeModelID: "openai/gpt-4.1-2025-04-14"},
			},
		}},
	}
}

func anthropicDeploymentGlobalConfig() Config {
	return Config{
		Deployments: map[string]DeploymentConfig{
			"anthropic-direct": {APIKey: "sk-ant"},
		},
		ActiveModel:      "anthropic/claude-sonnet-4-6",
		ExplorationModel: "anthropic/claude-haiku-4-5",
	}
}

func anthropicDeploymentModels() []ModelDef {
	return []ModelDef{
		anthropicDeploymentModel("anthropic/claude-opus-4-6", "claude-opus-4-6"),
		anthropicDeploymentModel("anthropic/claude-sonnet-4-6", "claude-sonnet-4-6"),
		anthropicDeploymentModel("anthropic/claude-haiku-4-5", "claude-haiku-4-5"),
	}
}

func anthropicDeploymentModel(canonicalID, nativeID string) ModelDef {
	return ModelDef{
		Provider:       ProviderAnthropic,
		OwnerProvider:  ProviderAnthropic,
		ID:             canonicalID,
		CanonicalID:    canonicalID,
		NativeModelIDs: []string{nativeID},
		Deployments: []ModelDeploymentDef{{
			DeploymentID:  "anthropic-direct",
			NativeModelID: nativeID,
		}},
	}
}

func writeRawProjectConfig(t *testing.T, repoRoot, raw string) {
	t.Helper()
	cfgDir := filepath.Join(repoRoot, configDir)
	if err := os.MkdirAll(cfgDir, 0o755); err != nil {
		t.Fatalf("MkdirAll: %v", err)
	}
	if err := os.WriteFile(filepath.Join(cfgDir, configFile), []byte(raw), 0o644); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}
}

func chatMessageContents(messages []chatMessage) []string {
	contents := make([]string, 0, len(messages))
	for _, message := range messages {
		contents = append(contents, message.content)
	}
	return contents
}

func expectRowsContainAll(t *testing.T, rows string, needles ...string) {
	t.Helper()
	plainRows := ansiEscRe.ReplaceAllString(rows, "")
	for _, needle := range needles {
		if !strings.Contains(rows, needle) && !strings.Contains(plainRows, needle) {
			t.Errorf("expected rows to contain %q:\n%s", needle, rows)
		}
	}
}

func expectRowsNotContainAny(t *testing.T, rows string, needles ...string) {
	t.Helper()
	plainRows := ansiEscRe.ReplaceAllString(rows, "")
	for _, needle := range needles {
		if strings.Contains(rows, needle) || strings.Contains(plainRows, needle) {
			t.Errorf("expected rows not to contain %q:\n%s", needle, rows)
		}
	}
}
