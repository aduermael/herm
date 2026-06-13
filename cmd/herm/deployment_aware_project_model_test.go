package main

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"langdag.com/langdag"
	"langdag.com/langdag/types"
)

func TestProjectModelProjectConfigSaveLoadNormalizesBareAnthropicIDs(t *testing.T) {
	repoRoot := t.TempDir()
	project := ProjectConfig{
		ActiveModel:      "claude-opus-4-6",
		ExplorationModel: "claude-haiku-4-5",
		Personality:      "project",
	}

	if err := saveProjectConfig(saveProjectConfigOptions{repoRoot: repoRoot, pc: project}); err != nil {
		t.Fatalf("saveProjectConfig: %v", err)
	}

	loaded := loadProjectConfig(repoRoot)
	if loaded.ActiveModel != "anthropic/claude-opus-4-6" {
		t.Fatalf("ActiveModel = %q, want anthropic/claude-opus-4-6", loaded.ActiveModel)
	}
	if loaded.ExplorationModel != "anthropic/claude-haiku-4-5" {
		t.Fatalf("ExplorationModel = %q, want anthropic/claude-haiku-4-5", loaded.ExplorationModel)
	}

	data, err := os.ReadFile(filepath.Join(repoRoot, configDir, configFile))
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	var saved ProjectConfig
	if err := json.Unmarshal(data, &saved); err != nil {
		t.Fatalf("Unmarshal saved project config: %v", err)
	}
	if saved.ActiveModel != "anthropic/claude-opus-4-6" || saved.ExplorationModel != "anthropic/claude-haiku-4-5" {
		t.Fatalf("saved project config was not canonicalized: %+v", saved)
	}
	if containsJSONKey(data, "deployments") || containsJSONKey(data, "routing") {
		t.Fatalf("project config must not write global-only deployment/routing state: %s", data)
	}
}

func TestProjectModelProjectConfigCannotOverwriteGlobalDeploymentState(t *testing.T) {
	repoRoot := t.TempDir()
	writeRawProjectConfig(t, repoRoot, `{
  "active_model": "claude-opus-4-6",
  "deployments": {"anthropic-direct": {"api_key": "project-secret"}},
  "routing": {"default": [{"deployments": [{"deployment_id": "openrouter", "weight": 100}]}]}
}`)

	global := Config{
		Deployments: map[string]DeploymentConfig{
			"anthropic-direct": {APIKey: "global-secret"},
		},
		Routing: &RoutingPolicy{Default: []RoutingStage{{
			Deployments: []DeploymentChoice{{DeploymentID: "anthropic-direct", Weight: 100}},
		}}},
		ActiveModel: "anthropic/claude-sonnet-4-6",
	}
	merged := mergeConfigs(mergeConfigsOptions{global: global, project: loadProjectConfig(repoRoot)})

	if merged.ActiveModel != "anthropic/claude-opus-4-6" {
		t.Fatalf("project active model did not apply: %q", merged.ActiveModel)
	}
	if got := merged.Deployments["anthropic-direct"].APIKey; got != "global-secret" {
		t.Fatalf("project config overwrote deployment credential: %q", got)
	}
	if merged.Routing == nil || merged.Routing.Default[0].Deployments[0].DeploymentID != "anthropic-direct" {
		t.Fatalf("project config overwrote routing: %+v", merged.Routing)
	}
}

func TestProjectModelRuntimeProjectNormalizationUsesCurrentCatalogModels(t *testing.T) {
	project := ProjectConfig{ActiveModel: "provider-native-new", ExplorationModel: "provider-fast-new"}
	models := []ModelDef{
		{
			ID:             "provider/new-model",
			CanonicalID:    "provider/new-model",
			NativeModelIDs: []string{"provider-native-new"},
		},
		{
			ID:             "provider/fast-model",
			CanonicalID:    "provider/fast-model",
			NativeModelIDs: []string{"provider-fast-new"},
		},
	}

	normalized := normalizeProjectConfigForModels(normalizeProjectConfigForModelsOptions{pc: project, models: models})
	if normalized.ActiveModel != "provider/new-model" {
		t.Fatalf("ActiveModel = %q, want provider/new-model", normalized.ActiveModel)
	}
	if normalized.ExplorationModel != "provider/fast-model" {
		t.Fatalf("ExplorationModel = %q, want provider/fast-model", normalized.ExplorationModel)
	}
}

func TestProjectModelRuntimeGlobalNormalizationUsesCurrentCatalogModels(t *testing.T) {
	cfg := Config{ActiveModel: "provider-native-new", ExplorationModel: "provider-fast-new"}
	models := []ModelDef{
		{
			ID:             "provider/new-model",
			CanonicalID:    "provider/new-model",
			NativeModelIDs: []string{"provider-native-new"},
		},
		{
			ID:             "provider/fast-model",
			CanonicalID:    "provider/fast-model",
			NativeModelIDs: []string{"provider-fast-new"},
		},
	}

	normalized := normalizeConfigForModels(configModelsOptions{cfg: cfg, models: models})
	if normalized.ActiveModel != "provider/new-model" {
		t.Fatalf("ActiveModel = %q, want provider/new-model", normalized.ActiveModel)
	}
	if normalized.ExplorationModel != "provider/fast-model" {
		t.Fatalf("ExplorationModel = %q, want provider/fast-model", normalized.ExplorationModel)
	}
}

func TestProjectModelSlashNativeIDNormalizesWhenCatalogDisambiguates(t *testing.T) {
	models := []ModelDef{{
		Provider:       ProviderOllama,
		OwnerProvider:  ProviderOllama,
		ID:             "ollama/hf.co/org/model:Q4",
		CanonicalID:    "ollama/hf.co/org/model:Q4",
		NativeModelIDs: []string{"hf.co/org/model:Q4"},
		Deployments: []ModelDeploymentDef{{
			DeploymentID:  "ollama-local",
			NativeModelID: "hf.co/org/model:Q4",
		}},
	}}

	project := normalizeProjectConfigForModels(normalizeProjectConfigForModelsOptions{pc: ProjectConfig{ActiveModel: "hf.co/org/model:Q4"}, models: models})
	if project.ActiveModel != "ollama/hf.co/org/model:Q4" {
		t.Fatalf("project ActiveModel = %q, want ollama/hf.co/org/model:Q4", project.ActiveModel)
	}
	global := normalizeConfigForModels(configModelsOptions{cfg: Config{ActiveModel: "hf.co/org/model:Q4"}, models: models})
	if global.ActiveModel != "ollama/hf.co/org/model:Q4" {
		t.Fatalf("global ActiveModel = %q, want ollama/hf.co/org/model:Q4", global.ActiveModel)
	}
}

func TestProjectModelExactCanonicalWinsOverSlashNativeIDCollision(t *testing.T) {
	offerings := []ModelIDMigrationOffering{
		{CanonicalModelID: "provider/model", DeploymentID: "direct", NativeModelID: "native-model"},
		{CanonicalModelID: "other/canonical", DeploymentID: "direct", NativeModelID: "provider/model"},
	}

	result := migrateStoredModelIDToCanonical(migrateStoredModelIDToCanonicalOptions{
		savedModelID: "provider/model",
		offerings:    offerings,
		smartDefault: "fallback/model",
	})
	if result.Status != ModelIDMigrationCanonicalMatch || result.CanonicalModelID != "provider/model" {
		t.Fatalf("canonical collision result = %+v, want exact canonical match", result)
	}
}

func TestProjectModelRuntimeExactCanonicalWinsOverNativeIDCollision(t *testing.T) {
	cfg := Config{
		Deployments: map[string]DeploymentConfig{
			"openrouter":   {APIKey: "sk-or"},
			"ollama-local": {BaseURL: "http://localhost:11434"},
		},
		ActiveModel: "vendor/model",
	}
	models := []ModelDef{
		{
			Provider:      ProviderOpenRouter,
			OwnerProvider: "vendor",
			ID:            "vendor/model",
			CanonicalID:   "vendor/model",
			Deployments: []ModelDeploymentDef{{
				DeploymentID:  "openrouter",
				NativeModelID: "vendor/model-native",
			}},
		},
		{
			Provider:       ProviderOllama,
			OwnerProvider:  ProviderOllama,
			ID:             "ollama/vendor/model",
			CanonicalID:    "ollama/vendor/model",
			NativeModelIDs: []string{"vendor/model"},
			Deployments: []ModelDeploymentDef{{
				DeploymentID:  "ollama-local",
				NativeModelID: "vendor/model",
			}},
		},
	}

	result := cfg.resolveActiveModelResult(models)
	if result.Status != configuredModelUsable || result.ResolvedModelID != "vendor/model" {
		t.Fatalf("runtime canonical collision result = %+v, want exact canonical vendor/model", result)
	}
}

func TestProjectModelRuntimeExactCanonicalUnavailableBeatsAvailableNativeIDAlias(t *testing.T) {
	cfg := Config{
		Deployments: map[string]DeploymentConfig{
			"ollama-local": {BaseURL: "http://localhost:11434"},
		},
		ActiveModel: "vendor/model",
	}
	models := []ModelDef{
		{
			Provider:      ProviderOpenRouter,
			OwnerProvider: "vendor",
			ID:            "vendor/model",
			CanonicalID:   "vendor/model",
			Deployments: []ModelDeploymentDef{{
				DeploymentID:  "openrouter",
				NativeModelID: "vendor/model-native",
			}},
		},
		{
			Provider:      ProviderOllama,
			OwnerProvider: ProviderOllama,
			ID:            "ollama/fallback",
			CanonicalID:   "ollama/fallback",
			Deployments: []ModelDeploymentDef{{
				DeploymentID:  "ollama-local",
				NativeModelID: "fallback",
			}},
		},
		{
			Provider:       ProviderOllama,
			OwnerProvider:  ProviderOllama,
			ID:             "ollama/vendor-model",
			CanonicalID:    "ollama/vendor-model",
			NativeModelIDs: []string{"vendor/model"},
			Deployments: []ModelDeploymentDef{{
				DeploymentID:  "ollama-local",
				NativeModelID: "vendor/model",
			}},
		},
	}

	result := cfg.resolveActiveModelResult(models)
	if !result.Fallback || result.Status != configuredModelUnavailable || result.ResolvedModelID != "ollama/fallback" {
		t.Fatalf("active exact unavailable collision result = %+v, want unavailable canonical with fallback", result)
	}
}

func TestProjectModelRuntimeExplorationExactCanonicalUnavailableBeatsAvailableNativeIDAlias(t *testing.T) {
	cfg := Config{
		Deployments: map[string]DeploymentConfig{
			"ollama-local": {BaseURL: "http://localhost:11434"},
		},
		ActiveModel:      "ollama/fallback",
		ExplorationModel: "vendor/model",
	}
	models := []ModelDef{
		{
			Provider:      ProviderOpenRouter,
			OwnerProvider: "vendor",
			ID:            "vendor/model",
			CanonicalID:   "vendor/model",
			Deployments: []ModelDeploymentDef{{
				DeploymentID:  "openrouter",
				NativeModelID: "vendor/model-native",
			}},
		},
		{
			Provider:      ProviderOllama,
			OwnerProvider: ProviderOllama,
			ID:            "ollama/fallback",
			CanonicalID:   "ollama/fallback",
			Deployments: []ModelDeploymentDef{{
				DeploymentID:  "ollama-local",
				NativeModelID: "fallback",
			}},
		},
		{
			Provider:       ProviderOllama,
			OwnerProvider:  ProviderOllama,
			ID:             "ollama/vendor-model",
			CanonicalID:    "ollama/vendor-model",
			NativeModelIDs: []string{"vendor/model"},
			Deployments: []ModelDeploymentDef{{
				DeploymentID:  "ollama-local",
				NativeModelID: "vendor/model",
			}},
		},
	}

	result := cfg.resolveExplorationModelResult(models)
	if !result.Fallback || result.Status != configuredModelUnavailable || result.ResolvedModelID != "ollama/fallback" {
		t.Fatalf("exploration exact unavailable collision result = %+v, want unavailable canonical with active fallback", result)
	}
}

func TestProjectModelProjectModelFallbackDiagnosticNamesConfiguredAndFallback(t *testing.T) {
	app := &App{
		globalConfig: Config{
			Deployments: map[string]DeploymentConfig{
				"openai-direct": {APIKey: "sk-openai"},
			},
			ActiveModel: "openai/gpt-4.1-2025-04-14",
		},
		projectConfig: ProjectConfig{ActiveModel: "anthropic/claude-opus-4-6"},
		models: []ModelDef{
			anthropicDeploymentModel("anthropic/claude-opus-4-6", "claude-opus-4-6"),
			{
				Provider:      ProviderOpenAI,
				OwnerProvider: ProviderOpenAI,
				ID:            "openai/gpt-4.1-2025-04-14",
				CanonicalID:   "openai/gpt-4.1-2025-04-14",
				Deployments: []ModelDeploymentDef{{
					DeploymentID:  "openai-direct",
					NativeModelID: "gpt-4.1-2025-04-14",
				}},
			},
		},
		configReady: true,
	}
	app.config = mergeConfigs(mergeConfigsOptions{global: app.globalConfig, project: app.projectConfig})

	app.showProjectModelDiagnostics()

	if len(app.messages) != 1 {
		t.Fatalf("messages = %d, want one diagnostic: %+v", len(app.messages), app.messages)
	}
	content := app.messages[0].content
	for _, want := range []string{`active_model "anthropic/claude-opus-4-6"`, "unavailable", `fallback model "openai/gpt-4.1-2025-04-14"`} {
		if !strings.Contains(content, want) {
			t.Fatalf("diagnostic %q missing %q", content, want)
		}
	}
	if got := app.config.resolveActiveModel(app.models); got != "openai/gpt-4.1-2025-04-14" {
		t.Fatalf("resolveActiveModel = %q, want fallback openai/gpt-4.1-2025-04-14", got)
	}
}

func TestProjectModelExplorationFallbackDiagnosticNamesConfiguredAndFallback(t *testing.T) {
	app := &App{
		globalConfig: Config{
			Deployments: map[string]DeploymentConfig{
				"openai-direct": {APIKey: "sk-openai"},
			},
			ActiveModel: "openai/gpt-4.1-2025-04-14",
		},
		projectConfig: ProjectConfig{ExplorationModel: "anthropic/claude-haiku-4-5"},
		models: []ModelDef{
			anthropicDeploymentModel("anthropic/claude-haiku-4-5", "claude-haiku-4-5"),
			{
				Provider:      ProviderOpenAI,
				OwnerProvider: ProviderOpenAI,
				ID:            "openai/gpt-4.1-2025-04-14",
				CanonicalID:   "openai/gpt-4.1-2025-04-14",
				Deployments: []ModelDeploymentDef{{
					DeploymentID:  "openai-direct",
					NativeModelID: "gpt-4.1-2025-04-14",
				}},
			},
		},
		configReady: true,
	}
	app.config = mergeConfigs(mergeConfigsOptions{global: app.globalConfig, project: app.projectConfig})

	app.showProjectModelDiagnostics()

	if len(app.messages) != 1 {
		t.Fatalf("messages = %d, want one diagnostic: %+v", len(app.messages), app.messages)
	}
	content := app.messages[0].content
	for _, want := range []string{`exploration_model "anthropic/claude-haiku-4-5"`, "unavailable", `fallback model "openai/gpt-4.1-2025-04-14"`} {
		if !strings.Contains(content, want) {
			t.Fatalf("diagnostic %q missing %q", content, want)
		}
	}
}

func TestProjectModelAmbiguousProjectModelFallsBackWithDiagnostic(t *testing.T) {
	cfg := Config{
		Deployments: map[string]DeploymentConfig{
			"anthropic-direct": {APIKey: "sk-ant"},
			"openrouter":       {APIKey: "sk-or"},
		},
		ActiveModel: "shared-native",
	}
	models := []ModelDef{
		{
			Provider:      ProviderAnthropic,
			OwnerProvider: ProviderAnthropic,
			ID:            "anthropic/ambiguous-a",
			CanonicalID:   "anthropic/ambiguous-a",
			NativeModelIDs: []string{
				"shared-native",
			},
			Deployments: []ModelDeploymentDef{{DeploymentID: "anthropic-direct", NativeModelID: "shared-native"}},
		},
		{
			Provider:      ProviderOpenRouter,
			OwnerProvider: ProviderOpenRouter,
			ID:            "openrouter/ambiguous-b",
			CanonicalID:   "openrouter/ambiguous-b",
			NativeModelIDs: []string{
				"shared-native",
			},
			Deployments: []ModelDeploymentDef{{DeploymentID: "openrouter", NativeModelID: "shared-native"}},
		},
		{
			Provider:      ProviderAnthropic,
			OwnerProvider: ProviderAnthropic,
			ID:            "anthropic/claude-sonnet-4-6",
			CanonicalID:   "anthropic/claude-sonnet-4-6",
			Deployments:   []ModelDeploymentDef{{DeploymentID: "anthropic-direct", NativeModelID: "claude-sonnet-4-6"}},
		},
	}

	result := cfg.resolveActiveModelResult(models)
	if !result.Fallback || result.Status != configuredModelAmbiguous {
		t.Fatalf("result = %+v, want ambiguous fallback", result)
	}
	if result.ResolvedModelID != "anthropic/claude-sonnet-4-6" {
		t.Fatalf("ResolvedModelID = %q, want anthropic/claude-sonnet-4-6", result.ResolvedModelID)
	}
	if !strings.Contains(result.Diagnostic, `"shared-native"`) || !strings.Contains(result.Diagnostic, "ambiguous") {
		t.Fatalf("Diagnostic = %q, want configured ID and ambiguous reason", result.Diagnostic)
	}
}

func TestProjectModelUnknownButCatalogValidCanonicalProjectIDResolves(t *testing.T) {
	cfg := Config{
		Deployments: map[string]DeploymentConfig{
			"openai-direct": {APIKey: "sk-openai"},
		},
		ActiveModel: "provider/new-catalog-model",
	}
	models := []ModelDef{{
		Provider:      ProviderOpenAI,
		OwnerProvider: ProviderOpenAI,
		ID:            "provider/new-catalog-model",
		CanonicalID:   "provider/new-catalog-model",
		Deployments: []ModelDeploymentDef{{
			DeploymentID:  "openai-direct",
			NativeModelID: "provider-new-native",
		}},
	}}

	if got := cfg.resolveActiveModel(models); got != "provider/new-catalog-model" {
		t.Fatalf("resolveActiveModel = %q, want provider/new-catalog-model", got)
	}
}

func TestProjectModelProjectConfigUnknownValuesRemainRoundTrippable(t *testing.T) {
	repoRoot := t.TempDir()
	project := ProjectConfig{
		ActiveModel:      "future-native-model",
		ExplorationModel: "future-fast-model",
	}
	if err := saveProjectConfig(saveProjectConfigOptions{repoRoot: repoRoot, pc: project}); err != nil {
		t.Fatalf("saveProjectConfig: %v", err)
	}
	loaded := loadProjectConfig(repoRoot)
	if loaded.ActiveModel != project.ActiveModel || loaded.ExplorationModel != project.ExplorationModel {
		t.Fatalf("loaded = %+v, want unknown values preserved %+v", loaded, project)
	}

	var raw map[string]any
	data, err := os.ReadFile(filepath.Join(repoRoot, configDir, configFile))
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		t.Fatalf("Unmarshal saved project config: %v", err)
	}
	if raw["active_model"] != "future-native-model" || raw["exploration_model"] != "future-fast-model" {
		t.Fatalf("saved JSON did not preserve unknown values: %s", data)
	}
}

func TestProjectModelProjectConfigAmbiguousValuesRemainRoundTrippable(t *testing.T) {
	repoRoot := t.TempDir()
	models := []ModelDef{
		{
			ID:             "provider/one",
			CanonicalID:    "provider/one",
			NativeModelIDs: []string{"claude-opus-4-6"},
			Deployments: []ModelDeploymentDef{{
				DeploymentID:  "provider-direct",
				NativeModelID: "claude-opus-4-6",
			}},
		},
		{
			ID:             "provider/two",
			CanonicalID:    "provider/two",
			NativeModelIDs: []string{"claude-opus-4-6"},
			Deployments: []ModelDeploymentDef{{
				DeploymentID:  "provider-direct",
				NativeModelID: "claude-opus-4-6",
			}},
		},
	}

	project := ProjectConfig{
		ActiveModel:      "claude-opus-4-6",
		ExplorationModel: "claude-opus-4-6",
	}
	if err := saveProjectConfig(saveProjectConfigOptions{repoRoot: repoRoot, pc: project, models: models}); err != nil {
		t.Fatalf("saveProjectConfig: %v", err)
	}
	loaded := loadProjectConfigForModels(loadProjectConfigForModelsOptions{repoRoot: repoRoot, models: models})
	if loaded.ActiveModel != project.ActiveModel || loaded.ExplorationModel != project.ExplorationModel {
		t.Fatalf("loaded = %+v, want ambiguous values preserved %+v", loaded, project)
	}

	var raw map[string]any
	data, err := os.ReadFile(filepath.Join(repoRoot, configDir, configFile))
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		t.Fatalf("Unmarshal saved project config: %v", err)
	}
	if raw["active_model"] != "claude-opus-4-6" || raw["exploration_model"] != "claude-opus-4-6" {
		t.Fatalf("saved JSON did not preserve ambiguous values: %s", data)
	}
}

func TestProjectModelGlobalConfigPathIsNotLoadedOrSavedAsProjectConfig(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	cfgDir := filepath.Join(home, configDir)
	if err := os.MkdirAll(cfgDir, 0o755); err != nil {
		t.Fatalf("MkdirAll: %v", err)
	}
	if err := os.WriteFile(filepath.Join(cfgDir, configFile), []byte(`{"active_model":"global-only"}`), 0o644); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}

	if projectConfigScopeAvailable(home) {
		t.Fatal("home/global config path should not be available as a project config scope")
	}
	if project := loadProjectConfig(home); project != (ProjectConfig{}) {
		t.Fatalf("loadProjectConfig(home) = %+v, want empty to avoid treating global config as project config", project)
	}
	if err := saveProjectConfig(saveProjectConfigOptions{repoRoot: home, pc: ProjectConfig{ActiveModel: "project-model"}}); err == nil {
		t.Fatal("saveProjectConfig(home) succeeded, want collision error")
	}
}

func TestProjectModelProjectConfigPathCollisionGuardResolvesSymlinks(t *testing.T) {
	home := t.TempDir()
	link := filepath.Join(t.TempDir(), "home-link")
	if err := os.Symlink(home, link); err != nil {
		t.Skipf("symlink unavailable: %v", err)
	}
	t.Setenv("HOME", home)
	if !sameFilesystemPath(sameFilesystemPathOptions{pathA: projectConfigPath(link), pathB: configPath()}) {
		t.Fatal("sameFilesystemPath should treat symlinked global/project config paths as the same file")
	}
	if projectConfigScopeAvailable(link) {
		t.Fatal("symlinked home path should not be available as a project config scope")
	}
}

func TestProjectModelClearResetsProjectModelDiagnosticDedupe(t *testing.T) {
	app := &App{
		projectConfig: ProjectConfig{ActiveModel: "missing-model"},
		config:        Config{ActiveModel: "missing-model"},
		models:        []ModelDef{},
		configReady:   true,
		headless:      true,
	}
	app.showProjectModelDiagnostics()
	if len(app.messages) != 1 {
		t.Fatalf("initial diagnostics = %d, want 1", len(app.messages))
	}

	app.handleCommand("/clear")
	app.showProjectModelDiagnostics()
	contents := strings.Join(chatMessageContents(app.messages), "\n")
	if !strings.Contains(contents, `active_model "missing-model" is unknown`) {
		t.Fatalf("diagnostic was not re-emitted after clear:\n%s", contents)
	}
}

func TestProjectModelCompactRequiresExplicitModel(t *testing.T) {
	store := newMockStorage()
	leafID := seedCompactableConversation(t, store)
	provider := &mockProvider{responses: []string{"compact summary"}, model: "openai/gpt-4.1-2025-04-14"}
	client := langdag.NewWithDeps(store, provider)
	app := &App{
		langdagClient: client,
		agentNodeID:   leafID,
		globalConfig: Config{
			Deployments: map[string]DeploymentConfig{
				"openai-direct": {APIKey: "sk-openai"},
			},
		},
		models: []ModelDef{{
			Provider:      ProviderOpenAI,
			OwnerProvider: ProviderOpenAI,
			ID:            "openai/gpt-4.1-2025-04-14",
			CanonicalID:   "openai/gpt-4.1-2025-04-14",
			Deployments: []ModelDeploymentDef{{
				DeploymentID:  "openai-direct",
				NativeModelID: "gpt-4.1-2025-04-14",
			}},
		}},
		configReady: true,
		resultCh:    make(chan any, 16),
		headless:    true,
	}
	app.config = mergeConfigs(mergeConfigsOptions{global: app.globalConfig, project: app.projectConfig})

	app.handleCompactCommand("/compact")

	if provider.lastRequest != nil {
		t.Fatalf("compact should not call provider without explicit model, got request for %q", provider.lastRequest.Model)
	}
	contents := strings.Join(chatMessageContents(app.messages), "\n")
	if !strings.Contains(contents, configMissingModelMessage) {
		t.Fatalf("compact should show missing-model message, got:\n%s", contents)
	}
}

func TestProjectModelCompactShowsExplorationFallbackDiagnosticAndUsesResolvedModel(t *testing.T) {
	store := newMockStorage()
	leafID := seedCompactableConversation(t, store)
	provider := &mockProvider{responses: []string{"compact summary"}, model: "openai/gpt-4.1-2025-04-14"}
	client := langdag.NewWithDeps(store, provider)
	app := &App{
		langdagClient: client,
		agentNodeID:   leafID,
		globalConfig: Config{
			Deployments: map[string]DeploymentConfig{
				"openai-direct": {APIKey: "sk-openai"},
			},
			ActiveModel: "openai/gpt-4.1-2025-04-14",
		},
		projectConfig: ProjectConfig{ExplorationModel: "anthropic/claude-haiku-4-5"},
		models: []ModelDef{
			anthropicDeploymentModel("anthropic/claude-haiku-4-5", "claude-haiku-4-5"),
			{
				Provider:      ProviderOpenAI,
				OwnerProvider: ProviderOpenAI,
				ID:            "openai/gpt-4.1-2025-04-14",
				CanonicalID:   "openai/gpt-4.1-2025-04-14",
				Deployments: []ModelDeploymentDef{{
					DeploymentID:  "openai-direct",
					NativeModelID: "gpt-4.1-2025-04-14",
				}},
			},
		},
		configReady: true,
		resultCh:    make(chan any, 16),
		headless:    true,
	}
	app.config = mergeConfigs(mergeConfigsOptions{global: app.globalConfig, project: app.projectConfig})

	app.handleCompactCommand("/compact")

	if provider.lastRequest == nil {
		t.Fatal("compact did not call provider")
	}
	if provider.lastRequest.Model != "openai/gpt-4.1-2025-04-14" {
		t.Fatalf("compact model = %q, want resolved active fallback openai/gpt-4.1-2025-04-14", provider.lastRequest.Model)
	}
	contents := strings.Join(chatMessageContents(app.messages), "\n")
	if !strings.Contains(contents, `exploration_model "anthropic/claude-haiku-4-5" is unavailable`) {
		t.Fatalf("compact did not show exploration fallback diagnostic:\n%s", contents)
	}
	if app.traceCollector != nil {
		t.Fatal("test setup should not have trace collector")
	}
}

func TestProjectModelCompactPreservesAssistantMetadataAndRecordsTrace(t *testing.T) {
	store := newMockStorage()
	leafID := seedCompactableConversation(t, store)
	metadata := types.AssistantNodeMetadata{
		ModelResolution: &types.ModelResolutionMetadata{
			CanonicalModelID: "anthropic/claude-opus-4-6",
			DeploymentID:     "anthropic-direct",
			NativeModelID:    "claude-opus-4-6",
		},
		PricingSnapshot: &types.PricingSnapshot{
			Status:   types.CostStatusKnown,
			Currency: "USD",
			Source:   types.CostSourceCatalog,
			RatesPer1M: map[string]float64{
				"input_tokens":  5,
				"output_tokens": 25,
			},
		},
	}
	rawMetadata, err := json.Marshal(metadata)
	if err != nil {
		t.Fatalf("Marshal metadata: %v", err)
	}
	store.mu.Lock()
	store.nodes[leafID].NodeType = types.NodeTypeAssistant
	store.nodes[leafID].Model = "anthropic/claude-opus-4-6"
	store.nodes[leafID].StopReason = "end_turn"
	store.nodes[leafID].Metadata = rawMetadata
	store.mu.Unlock()

	provider := &mockProvider{responses: []string{"compact summary"}, model: "openai/gpt-4.1-2025-04-14"}
	client := langdag.NewWithDeps(store, provider)
	tracePath := filepath.Join(t.TempDir(), "trace.json")
	app := &App{
		langdagClient: client,
		agentNodeID:   leafID,
		globalConfig: Config{
			ActiveModel: "openai/gpt-4.1-2025-04-14",
		},
		models:         []ModelDef{},
		configReady:    true,
		resultCh:       make(chan any, 16),
		traceCollector: NewTraceCollector("project-model-compact"),
		traceFilePath:  tracePath,
		headless:       true,
	}
	app.config = mergeConfigs(mergeConfigsOptions{global: app.globalConfig, project: app.projectConfig})

	app.handleCompactCommand("/compact")

	store.mu.Lock()
	var copied *types.Node
	for _, node := range store.nodes {
		if node.ID != leafID && node.NodeType == types.NodeTypeAssistant && node.Model == "anthropic/claude-opus-4-6" {
			copied = node
			break
		}
	}
	store.mu.Unlock()
	if copied == nil {
		t.Fatal("copied assistant node not found")
	}
	if copied.StopReason != "end_turn" {
		t.Fatalf("copied StopReason = %q, want end_turn", copied.StopReason)
	}
	copiedMetadata, err := types.ParseAssistantNodeMetadata(copied.Metadata)
	if err != nil {
		t.Fatalf("ParseAssistantNodeMetadata: %v", err)
	}
	if copiedMetadata == nil || copiedMetadata.ModelResolution == nil || copiedMetadata.ModelResolution.CanonicalModelID != "anthropic/claude-opus-4-6" {
		t.Fatalf("copied metadata = %+v", copiedMetadata)
	}

	app.traceCollector.mu.Lock()
	trace := app.traceCollector.buildTraceLocked()
	app.traceCollector.mu.Unlock()
	if trace.Info.Totals.Compactions != 1 {
		t.Fatalf("trace compactions = %d, want 1", trace.Info.Totals.Compactions)
	}
	if _, err := os.Stat(tracePath); err != nil {
		t.Fatalf("trace file was not flushed: %v", err)
	}
}

func TestProjectModelStartAgentPersistsCanonicalModelInUsageTraceAndMetadata(t *testing.T) {
	store := newMockStorage()
	provider := &canonicalMetadataProvider{}
	client := langdag.NewWithDeps(store, provider)
	app := &App{
		globalConfig:   anthropicDeploymentGlobalConfig(),
		projectConfig:  ProjectConfig{ActiveModel: "claude-opus-4-6", ExplorationModel: "claude-haiku-4-5"},
		models:         anthropicDeploymentModels(),
		configReady:    true,
		langdagClient:  client,
		resultCh:       make(chan any, 64),
		traceCollector: NewTraceCollector("project-model"),
		traceFilePath:  filepath.Join(t.TempDir(), "trace.json"),
		headless:       true,
		width:          80,
	}
	app.config = mergeConfigs(mergeConfigsOptions{global: app.globalConfig, project: app.projectConfig})

	app.startAgent("hello")
	drainStartedAgent(t, app)

	if provider.lastRequest == nil || provider.lastRequest.Model != "anthropic/claude-opus-4-6" {
		t.Fatalf("provider request model = %+v, want anthropic/claude-opus-4-6", provider.lastRequest)
	}
	var assistant *types.Node
	store.mu.Lock()
	for _, node := range store.nodes {
		if node.NodeType == types.NodeTypeAssistant {
			assistant = node
			break
		}
	}
	store.mu.Unlock()
	if assistant == nil {
		t.Fatal("assistant node was not saved")
	}
	if assistant.Model != "anthropic/claude-opus-4-6" {
		t.Fatalf("assistant node model = %q, want anthropic/claude-opus-4-6", assistant.Model)
	}
	metadata, err := types.ParseAssistantNodeMetadata(assistant.Metadata)
	if err != nil {
		t.Fatalf("ParseAssistantNodeMetadata: %v", err)
	}
	if metadata == nil || metadata.ModelResolution == nil || metadata.ModelResolution.CanonicalModelID != "anthropic/claude-opus-4-6" {
		t.Fatalf("assistant metadata model resolution = %+v", metadata)
	}

	app.traceCollector.mu.Lock()
	trace := app.traceCollector.buildTraceLocked()
	app.traceCollector.mu.Unlock()
	if trace.Info.Model != "anthropic/claude-opus-4-6" {
		t.Fatalf("trace model = %q, want anthropic/claude-opus-4-6", trace.Info.Model)
	}
	var llm TraceLLMResponse
	for _, raw := range trace.Events {
		var probe struct {
			Type string `json:"type"`
		}
		if err := json.Unmarshal(raw, &probe); err != nil || probe.Type != "llm_response" {
			continue
		}
		if err := json.Unmarshal(raw, &llm); err != nil {
			t.Fatalf("Unmarshal llm response: %v", err)
		}
		break
	}
	if llm.Model != "anthropic/claude-opus-4-6" {
		t.Fatalf("trace LLM model = %q, want anthropic/claude-opus-4-6", llm.Model)
	}
	if llm.ModelResolution == nil || llm.ModelResolution.CanonicalModelID != "anthropic/claude-opus-4-6" {
		t.Fatalf("trace model resolution = %+v", llm.ModelResolution)
	}
}

func TestProjectModelProjectTabGlobalHintShowsCanonicalGlobalModel(t *testing.T) {
	a := &App{
		cfgTab:          cfgTabProject,
		repoRoot:        t.TempDir(),
		cfgDraft:        Config{ActiveModel: "anthropic/claude-opus-4-6"},
		cfgProjectDraft: ProjectConfig{},
	}

	rows := a.buildConfigRows()
	if !rowsContain(rows, "(global: anthropic/claude-opus-4-6)") {
		t.Fatalf("project rows missing canonical global hint: %v", rows)
	}
}

func TestProjectModelExitConfigModeShowsProjectModelDiagnostic(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	app := &App{
		repoRoot:     t.TempDir(),
		configReady:  true,
		resultCh:     make(chan any, 8),
		headless:     true,
		width:        80,
		cfgDraft:     Config{Deployments: map[string]DeploymentConfig{"openai-direct": {APIKey: "sk-openai"}}, ActiveModel: "openai/gpt-4.1-2025-04-14"},
		globalConfig: Config{Deployments: map[string]DeploymentConfig{"openai-direct": {APIKey: "sk-openai"}}, ActiveModel: "openai/gpt-4.1-2025-04-14"},
		cfgProjectDraft: ProjectConfig{
			ActiveModel: "anthropic/claude-opus-4-6",
		},
		models: []ModelDef{
			anthropicDeploymentModel("anthropic/claude-opus-4-6", "claude-opus-4-6"),
			{
				Provider:      ProviderOpenAI,
				OwnerProvider: ProviderOpenAI,
				ID:            "openai/gpt-4.1-2025-04-14",
				CanonicalID:   "openai/gpt-4.1-2025-04-14",
				Deployments: []ModelDeploymentDef{{
					DeploymentID:  "openai-direct",
					NativeModelID: "gpt-4.1-2025-04-14",
				}},
			},
		},
	}
	app.config = mergeConfigs(mergeConfigsOptions{global: app.globalConfig, project: app.projectConfig})

	app.exitConfigMode(true)

	rows := strings.Join(chatMessageContents(app.messages), "\n")
	if !strings.Contains(rows, `active_model "anthropic/claude-opus-4-6" is unavailable`) {
		t.Fatalf("config save did not show project model diagnostic:\n%s", rows)
	}
	if strings.Contains(rows, "Using openai/gpt-4.1-2025-04-14") {
		t.Fatalf("config save should not show fallback model in 'Using' when diagnostic already covers it:\n%s", rows)
	}
}

func TestProjectModelCatalogRefreshUpdatesResolvedProjectModelDisplay(t *testing.T) {
	catalog := hermDeploymentCatalog("openai/canonical-refresh", "canonical-refresh", "openai/canonical-refresh")
	app := &App{
		globalConfig: Config{
			Deployments: map[string]DeploymentConfig{"openai-direct": {APIKey: "sk-openai"}},
		},
		projectConfig: ProjectConfig{ActiveModel: "openai/canonical-refresh"},
		configReady:   true,
		models:        []ModelDef{},
		headless:      true,
		width:         80,
	}
	app.config = mergeConfigs(mergeConfigsOptions{global: app.globalConfig, project: app.projectConfig})

	app.maybeShowInitialModels()
	if !app.shownInitialModel {
		t.Fatal("initial model display was not marked shown")
	}
	app.handleResult(catalogMsg{catalog: catalog})

	rows := strings.Join(chatMessageContents(app.messages), "\n")
	if !strings.Contains(rows, "Using active: openai/canonical-refresh") {
		t.Fatalf("catalog refresh did not update resolved project model display:\n%s", rows)
	}
	if strings.Contains(rows, `active_model "openai/canonical-refresh" is unknown`) {
		t.Fatalf("catalog refresh left stale unknown diagnostic in chat:\n%s", rows)
	}
	if app.lastModelDiagnostics != "" {
		t.Fatalf("catalog refresh left stale diagnostics: %q", app.lastModelDiagnostics)
	}
}

func TestProjectModelOllamaRefreshDoesNotDuplicateOfflineWarning(t *testing.T) {
	app := &App{
		globalConfig: Config{
			Deployments: map[string]DeploymentConfig{"ollama-local": {BaseURL: "http://localhost:11434"}},
			ActiveModel: "ollama/missing",
		},
		configReady: true,
		models:      []ModelDef{},
		headless:    true,
		width:       80,
	}
	app.config = app.globalConfig

	app.maybeShowInitialModels()
	app.handleResult(ollamaModelsMsg{})

	rows := strings.Join(chatMessageContents(app.messages), "\n")
	if count := strings.Count(rows, "Ollama unreachable"); count != 1 {
		t.Fatalf("Ollama offline warning count = %d, want 1:\n%s", count, rows)
	}
}

func TestProjectModelOllamaOfflineWarningDedupesWhenExplorationRefreshes(t *testing.T) {
	app := &App{
		globalConfig: Config{
			Deployments: map[string]DeploymentConfig{
				"ollama-local": {BaseURL: "http://localhost:11434"},
				"openrouter":   {APIKey: "sk-or"},
			},
			ActiveModel:      "ollama/missing",
			ExplorationModel: "vendor/fast-model",
		},
		configReady: true,
		models:      []ModelDef{},
		headless:    true,
		width:       80,
	}
	app.config = app.globalConfig

	app.maybeShowInitialModels()
	app.handleResult(ollamaModelsMsg{})
	app.models = mergeDynamicModels(mergeDynamicModelsOptions{base: app.models, dynamic: []ModelDef{{
		Provider:      ProviderOpenRouter,
		OwnerProvider: "vendor",
		ID:            "vendor/fast-model",
		CanonicalID:   "vendor/fast-model",
		Deployments: []ModelDeploymentDef{{
			DeploymentID:  "openrouter",
			NativeModelID: "vendor/fast-model",
		}},
	}}})
	app.refreshResolvedModelDisplay()

	rows := strings.Join(chatMessageContents(app.messages), "\n")
	if count := strings.Count(rows, "Ollama unreachable"); count != 1 {
		t.Fatalf("Ollama offline warning count = %d, want 1 after exploration refresh:\n%s", count, rows)
	}
	if !strings.Contains(rows, ", exploration: vendor/fast-model") {
		t.Fatalf("exploration refresh did not update model display:\n%s", rows)
	}
}

func TestProjectModelDynamicModelsRefreshStartupModelDisplay(t *testing.T) {
	app := &App{
		globalConfig: Config{
			Deployments: map[string]DeploymentConfig{
				"openrouter": {APIKey: "sk-or"},
			},
		},
		projectConfig: ProjectConfig{ActiveModel: "vendor/new-model"},
		configReady:   true,
		models:        []ModelDef{},
		headless:      true,
		width:         80,
	}
	app.config = mergeConfigs(mergeConfigsOptions{global: app.globalConfig, project: app.projectConfig})

	app.maybeShowInitialModels()
	startup := strings.Join(chatMessageContents(app.messages), "\n")
	if strings.Contains(startup, `active_model "vendor/new-model" is unknown`) {
		t.Fatalf("OpenRouter should trust configured native model IDs not in embedded catalog:\n%s", startup)
	}
	if !strings.Contains(startup, "Using active: vendor/new-model") {
		t.Fatalf("startup should use configured OpenRouter model:\n%s", startup)
	}

	app.handleResult(openRouterModelsMsg{models: []ModelDef{{
		Provider:      ProviderOpenRouter,
		OwnerProvider: "vendor",
		ID:            "vendor/new-model",
		CanonicalID:   "vendor/new-model",
		NativeModelIDs: []string{
			"vendor/new-model",
		},
		Deployments: []ModelDeploymentDef{{
			DeploymentID:  "openrouter",
			NativeModelID: "vendor/new-model",
		}},
	}}})

	rows := strings.Join(chatMessageContents(app.messages), "\n")
	if !strings.Contains(rows, "Using active: vendor/new-model") {
		t.Fatalf("dynamic model refresh did not update model display:\n%s", rows)
	}
}

func TestProjectModelOpenRouterTrustsUncataloguedNativeModel(t *testing.T) {
	app := &App{
		globalConfig: Config{
			Deployments: map[string]DeploymentConfig{
				"openrouter": {APIKey: "sk-or"},
			},
		},
		projectConfig: ProjectConfig{ActiveModel: "vendor/missing-model"},
		configReady:   true,
		models:        []ModelDef{},
		headless:      true,
		width:         80,
	}
	app.config = mergeConfigs(mergeConfigsOptions{global: app.globalConfig, project: app.projectConfig})

	app.maybeShowInitialModels()
	startup := strings.Join(chatMessageContents(app.messages), "\n")
	if strings.Contains(startup, `active_model "vendor/missing-model" is unknown`) {
		t.Fatalf("OpenRouter should trust configured native model IDs not in embedded catalog:\n%s", startup)
	}
	if !strings.Contains(startup, "Using active: vendor/missing-model") {
		t.Fatalf("startup should use configured OpenRouter model:\n%s", startup)
	}

	app.handleResult(openRouterModelsMsg{models: []ModelDef{{
		Provider:      ProviderOpenRouter,
		OwnerProvider: "vendor",
		ID:            "vendor/other-model",
		CanonicalID:   "vendor/other-model",
		Deployments: []ModelDeploymentDef{{
			DeploymentID:  "openrouter",
			NativeModelID: "vendor/other-model",
		}},
	}}})

	rows := strings.Join(chatMessageContents(app.messages), "\n")
	if strings.Contains(rows, `active_model "vendor/missing-model" is unknown`) {
		t.Fatalf("OpenRouter fetch should not warn for trusted native model ID:\n%s", rows)
	}
}

func TestRefreshResolvedModelDisplayExplorationOnly(t *testing.T) {
	app := &App{
		globalConfig: Config{
			Deployments: map[string]DeploymentConfig{"openrouter": {APIKey: "sk-or"}},
		},
		projectConfig: ProjectConfig{ExplorationModel: "openrouter/owl-alpha"},
		configReady:   true,
		models: []ModelDef{{
			Provider:    ProviderOpenRouter,
			ID:          "openrouter/owl-alpha",
			CanonicalID: "openrouter/owl-alpha",
			Deployments: []ModelDeploymentDef{{DeploymentID: "openrouter", NativeModelID: "openrouter/owl-alpha"}},
		}},
		headless: true,
		width:    80,
	}
	app.config = mergeConfigs(mergeConfigsOptions{global: app.globalConfig, project: app.projectConfig})

	app.refreshResolvedModelDisplay()
	rows := strings.Join(chatMessageContents(app.messages), "\n")
	if !strings.Contains(rows, "Using exploration: openrouter/owl-alpha (project)") {
		t.Fatalf("refresh should show exploration-only line:\n%s", rows)
	}
	if strings.Contains(rows, "Using active:") {
		t.Fatalf("exploration-only display should not include active line:\n%s", rows)
	}
}

func TestProjectModelDynamicModelsRefreshExplorationOnlyDisplay(t *testing.T) {
	app := &App{
		globalConfig: Config{
			Deployments: map[string]DeploymentConfig{
				"openrouter": {APIKey: "sk-or"},
			},
			ActiveModel: "openai/gpt-4.1-2025-04-14",
		},
		projectConfig: ProjectConfig{ExplorationModel: "vendor/fast-model"},
		configReady:   true,
		models: []ModelDef{{
			Provider:      ProviderOpenAI,
			OwnerProvider: ProviderOpenAI,
			ID:            "openai/gpt-4.1-2025-04-14",
			CanonicalID:   "openai/gpt-4.1-2025-04-14",
			Deployments: []ModelDeploymentDef{{
				DeploymentID:  "openrouter",
				NativeModelID: "openai/gpt-4.1-2025-04-14",
			}},
		}},
		headless: true,
		width:    80,
	}
	app.config = mergeConfigs(mergeConfigsOptions{global: app.globalConfig, project: app.projectConfig})

	app.maybeShowInitialModels()
	startup := strings.Join(chatMessageContents(app.messages), "\n")
	if !strings.Contains(startup, "Using active: openai/gpt-4.1-2025-04-14 (global), exploration: vendor/fast-model (project)") {
		t.Fatalf("startup should trust configured OpenRouter exploration model:\n%s", startup)
	}

	app.models = mergeDynamicModels(mergeDynamicModelsOptions{base: app.models, dynamic: []ModelDef{{
		Provider:      ProviderOpenRouter,
		OwnerProvider: "vendor",
		ID:            "vendor/fast-model",
		CanonicalID:   "vendor/fast-model",
		Deployments: []ModelDeploymentDef{{
			DeploymentID:  "openrouter",
			NativeModelID: "vendor/fast-model",
		}},
	}}})
	app.refreshResolvedModelDisplay()

	rows := strings.Join(chatMessageContents(app.messages), "\n")
	if !strings.Contains(rows, "Using active: openai/gpt-4.1-2025-04-14 (global), exploration: vendor/fast-model (project)") {
		t.Fatalf("dynamic model refresh did not update exploration display:\n%s", rows)
	}
}

type canonicalMetadataProvider struct {
	lastRequest *types.CompletionRequest
}

func (p *canonicalMetadataProvider) Complete(_ context.Context, req *types.CompletionRequest) (*types.CompletionResponse, error) {
	p.lastRequest = req
	return canonicalMetadataResponse(req.Model), nil
}

func (p *canonicalMetadataProvider) Stream(_ context.Context, req *types.CompletionRequest) (<-chan types.StreamEvent, error) {
	p.lastRequest = req
	ch := make(chan types.StreamEvent, 2)
	go func() {
		defer close(ch)
		ch <- types.StreamEvent{Type: types.StreamEventDelta, Content: "ok"}
		ch <- types.StreamEvent{Type: types.StreamEventDone, Response: canonicalMetadataResponse(req.Model)}
	}()
	return ch, nil
}

func (p *canonicalMetadataProvider) Name() string { return ProviderAnthropic }
func (p *canonicalMetadataProvider) Models() []types.ModelInfo {
	return nil
}

func canonicalMetadataResponse(model string) *types.CompletionResponse {
	return &types.CompletionResponse{
		ID:         "canonical-response",
		Model:      model,
		Provider:   ProviderAnthropic,
		Content:    []types.ContentBlock{{Type: "text", Text: "ok"}},
		StopReason: "end_turn",
		Usage:      types.Usage{InputTokens: 100, OutputTokens: 50},
		ModelResolution: &types.ModelResolutionMetadata{
			CanonicalModelID: model,
			OfferingID:       "anthropic-direct:claude-opus-4-6",
			DeploymentID:     "anthropic-direct",
			ProviderID:       ProviderAnthropic,
			APIProtocolID:    "anthropic-messages",
			NativeModelID:    "claude-opus-4-6",
		},
		PricingSnapshot: &types.PricingSnapshot{
			Status:   types.CostStatusKnown,
			Currency: "USD",
			Source:   types.CostSourceCatalog,
			RatesPer1M: map[string]float64{
				"input_tokens":  5,
				"output_tokens": 25,
			},
		},
	}
}

func seedCompactableConversation(t *testing.T, store *mockStorage) string {
	t.Helper()
	parentID := ""
	rootID := ""
	var leafID string
	for i := 0; i < compactKeepRecent+2; i++ {
		nodeID := "n" + string(rune('0'+i))
		if i == 0 {
			rootID = nodeID
		}
		nodeType := types.NodeTypeUser
		if i%2 == 1 {
			nodeType = types.NodeTypeAssistant
		}
		node := &types.Node{
			ID:           nodeID,
			ParentID:     parentID,
			RootID:       rootID,
			Sequence:     i,
			NodeType:     nodeType,
			Content:      "content",
			SystemPrompt: "system",
			CreatedAt:    time.Now(),
		}
		if err := store.CreateNode(context.Background(), node); err != nil {
			t.Fatalf("CreateNode: %v", err)
		}
		parentID = nodeID
		leafID = nodeID
	}
	return leafID
}

func drainStartedAgent(t *testing.T, app *App) {
	t.Helper()
	t.Cleanup(func() {
		if app.agentTicker != nil {
			app.agentTicker.Stop()
		}
	})
	deadline := time.After(5 * time.Second)
	for {
		select {
		case event, ok := <-app.agent.Events():
			if !ok {
				return
			}
			app.handleAgentEvent(event)
			if event.Type == EventDone {
				return
			}
		case <-app.agent.DoneCh():
			app.drainAgentEvents()
			if !app.agentRunning {
				return
			}
		case <-deadline:
			t.Fatal("timed out waiting for agent")
		}
	}
}
