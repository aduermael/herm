package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestBuildConfigRowsRoutingReadOnlyPreviewContract(t *testing.T) {
	app := phase9RoutingApp()

	rows := strings.Join(app.buildConfigRows(), "\n")

	expectRowsContainAll(t, rows,
		"Routing is global",
		"Model routes override provider routes; provider routes override the default route.",
		"Default: stage 1 tries openai-direct (weight 70) and openrouter (weight 30), retries 2; stage 2 tries openrouter (weight 100), retries 1.",
		"routing JSON",
		`"default": [`,
		`"providers": {`,
		`"models": {`,
		"Ctrl+E=edit global JSON",
	)
	expectRowsNotContainAny(t, rows,
		"Route syntax:",
		"Default Route:",
		"OpenAI Route:",
		"sk-openai-secret",
		"api_key",
		`"active_model"`,
		`"config_version"`,
	)
}

func TestRoutingJSONPreviewTruncatesLongPolicies(t *testing.T) {
	app := phase9RoutingApp()
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
		"routing JSON",
		"...",
		"more routing JSON lines",
	)
}

func TestRoutingAdvancedJSONEditKeyIsOnlyRoutingEditEntry(t *testing.T) {
	app := phase9RoutingApp()

	fields := app.routingTabFields()
	if len(fields) > 1 {
		t.Fatalf("routingTabFields returned %d fields, want at most one advanced JSON edit entry: %+v", len(fields), fields)
	}
	if len(fields) == 1 && fields[0].label != "Edit Global Config JSON" {
		t.Fatalf("routing edit entry label = %q, want %q", fields[0].label, "Edit Global Config JSON")
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

	global := phase9AnthropicGlobalConfig()
	global.ActiveModel = "anthropic/claude-sonnet-4-6"
	effective := mergeConfigs(mergeConfigsOptions{global: global, project: loadProjectConfig(repoRoot)})

	if effective.ActiveModel != "anthropic/claude-opus-4-6" {
		t.Fatalf("merged ActiveModel = %q, want canonical project override anthropic/claude-opus-4-6", effective.ActiveModel)
	}
	if got := effective.resolveActiveModel(phase9AnthropicModels()); got != "anthropic/claude-opus-4-6" {
		t.Fatalf("resolveActiveModel = %q, want project override anthropic/claude-opus-4-6", got)
	}
}

func TestStartAgentStartupAndRuntimeUseProjectBareCanonicalModel(t *testing.T) {
	repoRoot := t.TempDir()
	writeRawProjectConfig(t, repoRoot, `{"active_model":"claude-opus-4-6","exploration_model":"claude-haiku-4-5"}`)

	app := &App{
		globalConfig:  phase9AnthropicGlobalConfig(),
		models:        phase9AnthropicModels(),
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
	if !strings.Contains(startupRows, "Using anthropic/claude-opus-4-6") {
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

func phase9RoutingApp() *App {
	return &App{
		cfgTab: 1,
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

func phase9AnthropicGlobalConfig() Config {
	return Config{
		Deployments: map[string]DeploymentConfig{
			"anthropic-direct": {APIKey: "sk-ant"},
		},
		ActiveModel:      "anthropic/claude-sonnet-4-6",
		ExplorationModel: "anthropic/claude-haiku-4-5",
	}
}

func phase9AnthropicModels() []ModelDef {
	return []ModelDef{
		phase9AnthropicModel("anthropic/claude-opus-4-6", "claude-opus-4-6"),
		phase9AnthropicModel("anthropic/claude-sonnet-4-6", "claude-sonnet-4-6"),
		phase9AnthropicModel("anthropic/claude-haiku-4-5", "claude-haiku-4-5"),
	}
}

func phase9AnthropicModel(canonicalID, nativeID string) ModelDef {
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
	for _, needle := range needles {
		if !strings.Contains(rows, needle) {
			t.Errorf("expected rows to contain %q:\n%s", needle, rows)
		}
	}
}

func expectRowsNotContainAny(t *testing.T, rows string, needles ...string) {
	t.Helper()
	for _, needle := range needles {
		if strings.Contains(rows, needle) {
			t.Errorf("expected rows not to contain %q:\n%s", needle, rows)
		}
	}
}
