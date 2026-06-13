package main

import (
	"strings"
	"testing"

	"langdag.com/langdag"
)

// TestEffectiveModelConfigHonorsOverrides verifies that effectiveModelConfig
// returns the merged config (with CLI overrides applied) so that
// modelsReadyForAgent passes when an active model is supplied via
// --config-overrides, even though the saved global/project configs have no
// model set.
func TestEffectiveModelConfigHonorsOverrides(t *testing.T) {
	tests := []struct {
		name               string
		globalConfig       Config
		projectConfig      ProjectConfig
		cliConfigOverrides string
		wantReady          bool
	}{
		{
			name:               "no saved model, override supplies active model",
			globalConfig:       Config{Deployments: map[string]DeploymentConfig{"anthropic": {APIKey: "sk-x"}}},
			cliConfigOverrides: `{"active_model":"anthropic/claude-sonnet-4-6"}`,
			wantReady:          true,
		},
		{
			name:               "no saved model, override supplies exploration model",
			globalConfig:       Config{Deployments: map[string]DeploymentConfig{"openai-direct": {APIKey: "sk-y"}}},
			cliConfigOverrides: `{"exploration_model":"openai/gpt-4.1-mini-2025-04-14"}`,
			wantReady:          true,
		},
		{
			name:          "no override, no saved model → gate blocks",
			globalConfig:  Config{Deployments: map[string]DeploymentConfig{"anthropic": {APIKey: "sk-x"}}},
			projectConfig: ProjectConfig{},
			wantReady:     false,
		},
		{
			name:               "empty override string, saved global model → gate passes",
			globalConfig:       Config{Deployments: map[string]DeploymentConfig{"anthropic": {APIKey: "sk-x"}}, ActiveModel: "anthropic/claude-sonnet-4-6"},
			cliConfigOverrides: "",
			wantReady:          true,
		},
		{
			name:               "override with project model already set → gate passes",
			globalConfig:       Config{Deployments: map[string]DeploymentConfig{"openrouter": {APIKey: "sk-or"}}},
			projectConfig:      ProjectConfig{ActiveModel: "openrouter/some-model"},
			cliConfigOverrides: `{"active_model":"openrouter/other-model"}`,
			wantReady:          true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			app := &App{
				globalConfig:       tt.globalConfig,
				projectConfig:      tt.projectConfig,
				cliConfigOverrides: tt.cliConfigOverrides,
			}
			app.rebuildEffectiveConfig()

			got := modelsReadyForAgent(app.effectiveModelConfig())
			if got != tt.wantReady {
				t.Fatalf("modelsReadyForAgent(effectiveModelConfig()) = %v, want %v", got, tt.wantReady)
			}
		})
	}
}

// TestCompactGateBlocksWithoutExplicitModel verifies that /compact is blocked
// (no LLM call made) when no explicit model is configured, regardless of
// provider or deployment setup.
func TestCompactGateBlocksWithoutExplicitModel(t *testing.T) {
	tests := []struct {
		name         string
		globalConfig Config
	}{
		{
			name:         "anthropic key set but no model selected",
			globalConfig: Config{Deployments: map[string]DeploymentConfig{"anthropic": {APIKey: "sk-ant"}}},
		},
		{
			name:         "openai key set but no model selected",
			globalConfig: Config{Deployments: map[string]DeploymentConfig{"openai-direct": {APIKey: "sk-oai"}}},
		},
		{
			name:         "openrouter key set but no model selected",
			globalConfig: Config{Deployments: map[string]DeploymentConfig{"openrouter": {APIKey: "sk-or"}}},
		},
		{
			name: "multiple providers configured but no model selected",
			globalConfig: Config{Deployments: map[string]DeploymentConfig{
				"anthropic":    {APIKey: "sk-ant"},
				"openai-direct": {APIKey: "sk-oai"},
				"openrouter":   {APIKey: "sk-or"},
			}},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			store := newMockStorage()
			leafID := seedCompactableConversation(t, store)
			provider := &mockProvider{responses: []string{"summary"}, model: "any-model"}
			client := langdag.NewWithDeps(store, provider)

			app := &App{
				langdagClient: client,
				agentNodeID:   leafID,
				globalConfig:  tt.globalConfig,
				configReady:   true,
				resultCh:      make(chan any, 16),
				headless:      true,
			}
			app.config = mergeConfigs(mergeConfigsOptions{global: app.globalConfig, project: app.projectConfig})

			app.handleCompactCommand("/compact")

			if provider.lastRequest != nil {
				t.Fatal("compact should NOT make an LLM call without explicit model")
			}
			contents := strings.Join(chatMessageContents(app.messages), "\n")
			if !strings.Contains(contents, configMissingModelMessage) {
				t.Fatalf("expected missing-model message, got:\n%s", contents)
			}
		})
	}
}

// TestCompactGatePassesWithExplicitModel verifies that /compact proceeds with
// an LLM call when an explicit model is configured.
func TestCompactGatePassesWithExplicitModel(t *testing.T) {
	tests := []struct {
		name          string
		globalConfig  Config
		projectConfig ProjectConfig
		models        []ModelDef
	}{
		{
			name: "global active model set",
			globalConfig: Config{
				Deployments: map[string]DeploymentConfig{"anthropic": {APIKey: "sk-ant"}},
				ActiveModel: "anthropic/test-model",
			},
			models: []ModelDef{{ID: "anthropic/test-model", Provider: ProviderAnthropic, Deployments: []ModelDeploymentDef{{DeploymentID: "anthropic", NativeModelID: "test-model"}}}},
		},
		{
			name:         "project exploration model set",
			globalConfig: Config{Deployments: map[string]DeploymentConfig{"openrouter": {APIKey: "sk-or"}}},
			projectConfig: ProjectConfig{ExplorationModel: "openrouter/cheap-model"},
			models:       []ModelDef{{ID: "openrouter/cheap-model", Provider: ProviderOpenRouter, Deployments: []ModelDeploymentDef{{DeploymentID: "openrouter", NativeModelID: "cheap-model"}}}},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			store := newMockStorage()
			leafID := seedCompactableConversation(t, store)
			provider := &mockProvider{responses: []string{"compact summary"}, model: "any"}
			client := langdag.NewWithDeps(store, provider)

			app := &App{
				langdagClient: client,
				agentNodeID:   leafID,
				globalConfig:  tt.globalConfig,
				projectConfig: tt.projectConfig,
				models:        tt.models,
				configReady:   true,
				resultCh:      make(chan any, 16),
				headless:      true,
			}
			app.config = mergeConfigs(mergeConfigsOptions{global: app.globalConfig, project: app.projectConfig})

			app.handleCompactCommand("/compact")

			if provider.lastRequest == nil {
				t.Fatal("compact should make an LLM call with explicit model configured")
			}
		})
	}
}

// TestProviderInferenceForUncataloguedModels verifies that
// configuredProviderForModelID correctly infers the provider for model IDs
// not in the catalog, across all provider scenarios.
func TestProviderInferenceForUncataloguedModels(t *testing.T) {
	tests := []struct {
		name         string
		cfg          Config
		models       []ModelDef
		modelID      string
		wantProvider string
	}{
		{
			name:         "uncatalogued model with openrouter configured → openrouter",
			cfg:          Config{Deployments: map[string]DeploymentConfig{"openrouter": {APIKey: "sk-or"}}},
			models:       []ModelDef{},
			modelID:      "vendor/some-new-model:free",
			wantProvider: ProviderOpenRouter,
		},
		{
			name:         "uncatalogued model with only anthropic configured → empty",
			cfg:          Config{Deployments: map[string]DeploymentConfig{"anthropic": {APIKey: "sk-ant"}}},
			models:       []ModelDef{},
			modelID:      "vendor/unknown-model",
			wantProvider: "",
		},
		{
			name:         "catalogued model returns catalog provider regardless of openrouter",
			cfg:          Config{Deployments: map[string]DeploymentConfig{"anthropic": {APIKey: "sk-ant"}, "openrouter": {APIKey: "sk-or"}}},
			models:       []ModelDef{{ID: "anthropic/claude-sonnet-4-6", Provider: ProviderAnthropic}},
			modelID:      "anthropic/claude-sonnet-4-6",
			wantProvider: ProviderAnthropic,
		},
		{
			name: "ollama-prefix model with ollama URL → ollama takes precedence over openrouter",
			cfg: Config{
				Deployments:   map[string]DeploymentConfig{"openrouter": {APIKey: "sk-or"}},
				OllamaBaseURL: "http://localhost:11434",
			},
			models:       []ModelDef{},
			modelID:      "ollama/llama3",
			wantProvider: ProviderOllama,
		},
		{
			name: "uncatalogued model with ollama URL configured → ollama (no openrouter)",
			cfg: Config{
				Deployments:   map[string]DeploymentConfig{"anthropic": {APIKey: "sk-ant"}},
				OllamaBaseURL: "http://localhost:11434",
			},
			models:       []ModelDef{},
			modelID:      "my-custom-model",
			wantProvider: ProviderOllama,
		},
		{
			name:         "empty model ID → empty provider",
			cfg:          Config{Deployments: map[string]DeploymentConfig{"openrouter": {APIKey: "sk-or"}}},
			models:       []ModelDef{},
			modelID:      "",
			wantProvider: "",
		},
		{
			name: "ollama URL + openrouter both configured, uncatalogued model → ollama wins",
			cfg: Config{
				Deployments:   map[string]DeploymentConfig{"openrouter": {APIKey: "sk-or"}},
				OllamaBaseURL: "http://localhost:11434",
			},
			models:       []ModelDef{},
			modelID:      "some-local-model",
			wantProvider: ProviderOllama,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := configuredProviderForModelID(configuredProviderForModelIDOptions{
				cfg:     tt.cfg,
				models:  tt.models,
				modelID: tt.modelID,
			})
			if got != tt.wantProvider {
				t.Fatalf("configuredProviderForModelID() = %q, want %q", got, tt.wantProvider)
			}
		})
	}
}

// TestStartAgentGateWithVariousConfigs verifies the explicit-model gate
// in startAgent across different configuration scenarios.
func TestStartAgentGateWithVariousConfigs(t *testing.T) {
	tests := []struct {
		name               string
		globalConfig       Config
		projectConfig      ProjectConfig
		cliConfigOverrides string
		models             []ModelDef
		wantAgentStarted   bool
	}{
		{
			name:             "global active model → agent starts",
			globalConfig:     Config{Deployments: map[string]DeploymentConfig{"openrouter": {APIKey: "sk-x"}}, ActiveModel: "openrouter/test"},
			models:           []ModelDef{{ID: "openrouter/test", Provider: ProviderOpenRouter, Deployments: []ModelDeploymentDef{{DeploymentID: "openrouter", NativeModelID: "test"}}}},
			wantAgentStarted: true,
		},
		{
			name:             "project exploration model only → agent starts",
			globalConfig:     Config{Deployments: map[string]DeploymentConfig{"openrouter": {APIKey: "sk-or"}}},
			projectConfig:    ProjectConfig{ExplorationModel: "openrouter/cheap"},
			models:           []ModelDef{{ID: "openrouter/cheap", Provider: ProviderOpenRouter, Deployments: []ModelDeploymentDef{{DeploymentID: "openrouter", NativeModelID: "cheap"}}}},
			wantAgentStarted: true,
		},
		{
			name:               "CLI override active model → agent starts",
			globalConfig:       Config{Deployments: map[string]DeploymentConfig{"openai-direct": {APIKey: "sk-oai"}}},
			cliConfigOverrides: `{"active_model":"openai/gpt-4.1-2025-04-14"}`,
			models:             []ModelDef{{ID: "openai/gpt-4.1-2025-04-14", Provider: ProviderOpenAI, Deployments: []ModelDeploymentDef{{DeploymentID: "openai-direct", NativeModelID: "gpt-4.1-2025-04-14"}}}},
			wantAgentStarted:   true,
		},
		{
			name:             "provider key set but no model → agent blocked",
			globalConfig:     Config{Deployments: map[string]DeploymentConfig{"openrouter": {APIKey: "sk-x"}}},
			models:           []ModelDef{{ID: "openrouter/test", Provider: ProviderOpenRouter}},
			wantAgentStarted: false,
		},
		{
			name:             "no provider keys and no model → agent blocked",
			globalConfig:     Config{},
			wantAgentStarted: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			app := &App{
				globalConfig:       tt.globalConfig,
				projectConfig:      tt.projectConfig,
				cliConfigOverrides: tt.cliConfigOverrides,
				configReady:        true,
				models:             tt.models,
				langdagClient:      newTestClient("ok"),
				headless:           true,
				width:              80,
			}
			app.rebuildEffectiveConfig()

			app.startAgent("test message")

			agentStarted := app.agent != nil && app.agentRunning
			if agentStarted != tt.wantAgentStarted {
				t.Fatalf("agent started = %v, want %v", agentStarted, tt.wantAgentStarted)
			}
		})
	}
}
