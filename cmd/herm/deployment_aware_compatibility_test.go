package main

import (
	"encoding/json"
	"math"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"langdag.com/langdag/types"
)

const deploymentAwareCompatibilityFixtureDir = "testdata/deployment_aware_compatibility"

func readDeploymentAwareCompatibilityFixture(t *testing.T, name string) []byte {
	t.Helper()
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller failed")
	}
	data, err := os.ReadFile(filepath.Join(filepath.Dir(file), deploymentAwareCompatibilityFixtureDir, name))
	if err != nil {
		t.Fatalf("read fixture %s: %v", name, err)
	}
	return data
}

func writeDeploymentAwareCompatibilityConfigFixture(t *testing.T, dir, fixture string) {
	t.Helper()
	cfgDir := filepath.Join(dir, configDir)
	if err := os.MkdirAll(cfgDir, 0o755); err != nil {
		t.Fatalf("mkdir config dir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(cfgDir, configFile), readDeploymentAwareCompatibilityFixture(t, fixture), 0o644); err != nil {
		t.Fatalf("write config fixture: %v", err)
	}
}

func TestOldGlobalConfigFixtureLoadsFlatFields(t *testing.T) {
	dir := t.TempDir()
	writeDeploymentAwareCompatibilityConfigFixture(t, dir, "old_global_config.json")

	cfg, err := loadConfigFrom(dir)
	if err != nil {
		t.Fatalf("loadConfigFrom: %v", err)
	}

	if cfg.ActiveModel != "openai/gpt-4.1-2025-04-14" {
		t.Errorf("ActiveModel = %q", cfg.ActiveModel)
	}
	if cfg.ExplorationModel != "anthropic/claude-haiku-4-5" {
		t.Errorf("ExplorationModel = %q", cfg.ExplorationModel)
	}
	if cfg.OpenAIAPIKey == "" || cfg.AnthropicAPIKey == "" || cfg.OpenRouterAPIKey == "" || cfg.GeminiAPIKey == "" || cfg.OllamaBaseURL == "" {
		t.Fatalf("fixture did not load expected flat provider credentials: %+v", cfg)
	}
	if cfg.GrokAPIKey != "" {
		t.Errorf("GrokAPIKey = %q, want empty to keep one unconfigured provider in the fixture", cfg.GrokAPIKey)
	}
	providers := cfg.configuredProviders()
	for _, provider := range []string{ProviderAnthropic, ProviderOpenAI, ProviderOpenRouter, ProviderGemini, ProviderOllama} {
		if !providers[provider] {
			t.Errorf("configuredProviders missing %q", provider)
		}
	}
	if providers[ProviderGrok] {
		t.Error("configuredProviders should not include grok for the old global fixture")
	}
	if cfg.effectiveGitCoAuthor() {
		t.Error("git_co_author=false should remain a readable flat config field")
	}
	if !cfg.effectiveThinking() {
		t.Error("thinking=true should remain a readable flat config field")
	}
}

func TestOldProjectConfigFixtureMergesBareModelIDs(t *testing.T) {
	globalDir := t.TempDir()
	projectDir := t.TempDir()
	writeDeploymentAwareCompatibilityConfigFixture(t, globalDir, "old_global_config.json")
	writeDeploymentAwareCompatibilityConfigFixture(t, projectDir, "old_project_config.json")

	global, err := loadConfigFrom(globalDir)
	if err != nil {
		t.Fatalf("loadConfigFrom: %v", err)
	}
	project := loadProjectConfig(projectDir)
	merged := mergeConfigs(mergeConfigsOptions{global: global, project: project})

	models := []ModelDef{
		{Provider: ProviderAnthropic, ID: "claude-sonnet-4-6"},
		{Provider: ProviderAnthropic, ID: "claude-haiku-4-5"},
		{Provider: ProviderOpenAI, ID: "gpt-4.1-2025-04-14"},
	}
	if got := merged.resolveActiveModel(models); got != "claude-sonnet-4-6" {
		t.Errorf("resolveActiveModel = %q, want project bare model ID", got)
	}
	if got := merged.resolveExplorationModel(models); got != "claude-haiku-4-5" {
		t.Errorf("resolveExplorationModel = %q, want project bare model ID", got)
	}
	if merged.Personality != "project terse" {
		t.Errorf("Personality = %q, want project override", merged.Personality)
	}
	if merged.OpenAIAPIKey == "" || merged.AnthropicAPIKey == "" {
		t.Error("project config should not replace global flat credentials")
	}
}

func TestSmartDefaultsRemainProviderKeyed(t *testing.T) {
	models := []ModelDef{
		{Provider: ProviderAnthropic, ID: "claude-sonnet-4-6"},
		{Provider: ProviderAnthropic, ID: "claude-haiku-4-5"},
		{Provider: ProviderOpenAI, ID: "gpt-4.1-2025-04-14"},
		{Provider: ProviderOpenAI, ID: "gpt-4.1-mini-2025-04-14"},
	}

	anthropicFirst := Config{AnthropicAPIKey: "ant", OpenAIAPIKey: "openai"}
	if got := anthropicFirst.defaultLangdagProvider(); got != ProviderAnthropic {
		t.Fatalf("defaultLangdagProvider = %q, want anthropic", got)
	}
	if got := anthropicFirst.resolveActiveModel(models); got != "claude-sonnet-4-6" {
		t.Errorf("anthropic active default = %q", got)
	}
	if got := anthropicFirst.resolveExplorationModel(models); got != "claude-sonnet-4-6" {
		t.Errorf("unset exploration should follow active resolution = %q", got)
	}

	openAIOnly := Config{OpenAIAPIKey: "openai"}
	if got := openAIOnly.defaultLangdagProvider(); got != ProviderOpenAI {
		t.Fatalf("defaultLangdagProvider = %q, want openai", got)
	}
	if got := openAIOnly.resolveActiveModel(models); got != "gpt-4.1-2025-04-14" {
		t.Errorf("openai active default = %q", got)
	}
	if got := openAIOnly.resolveExplorationModel(models); got != "gpt-4.1-2025-04-14" {
		t.Errorf("unset exploration should follow active resolution = %q", got)
	}
}

func TestModelPickerAvailabilityUsesConfiguredProviders(t *testing.T) {
	dir := t.TempDir()
	writeDeploymentAwareCompatibilityConfigFixture(t, dir, "old_global_config.json")
	cfg, err := loadConfigFrom(dir)
	if err != nil {
		t.Fatalf("loadConfigFrom: %v", err)
	}

	models := []ModelDef{
		{Provider: ProviderAnthropic, ID: "claude-sonnet-4-6", PromptPrice: 3, CompletionPrice: 15},
		{Provider: ProviderOpenAI, ID: "gpt-4.1-2025-04-14", PromptPrice: 2, CompletionPrice: 8},
		{Provider: ProviderOpenRouter, ID: "z-ai/glm-4.5-air:free"},
		{Provider: ProviderGemini, ID: "gemini-2.5-pro", PromptPrice: 1.25, CompletionPrice: 10},
		{Provider: ProviderOllama, ID: "llama3.1:8b"},
		{Provider: ProviderGrok, ID: "grok-4-1-fast-reasoning", PromptPrice: 3, CompletionPrice: 15},
	}

	available := cfg.availableModels(models)
	seen := map[string]bool{}
	for _, m := range available {
		seen[m.Provider] = true
	}
	for _, provider := range []string{ProviderAnthropic, ProviderOpenAI, ProviderOpenRouter, ProviderGemini, ProviderOllama} {
		if !seen[provider] {
			t.Errorf("availableModels missing configured provider %q", provider)
		}
	}
	if seen[ProviderGrok] {
		t.Error("availableModels should not include grok without a grok key")
	}

	a := &App{cfgDraft: cfg, models: models, resultCh: make(chan any, 16)}
	a.doOpenConfigModelPicker(doOpenConfigModelPickerOptions{
		models:       models,
		getCurrentID: func() string { return cfg.ActiveModel },
		onSelect:     func(string) {},
	})
	if !a.menuActive {
		t.Fatal("model picker should open when configured providers have available models")
	}
	for _, m := range a.menuModels {
		if m.Provider == ProviderGrok {
			t.Fatalf("model picker included unconfigured grok model: %+v", m)
		}
	}
}

func TestOllamaOfflineFixtureTrustsSavedModels(t *testing.T) {
	var fixture struct {
		BaseURL          string     `json:"base_url"`
		ActiveModel      string     `json:"active_model"`
		ExplorationModel string     `json:"exploration_model"`
		LiveModels       []ModelDef `json:"live_models"`
	}
	if err := json.Unmarshal(readDeploymentAwareCompatibilityFixture(t, "ollama_offline_models.json"), &fixture); err != nil {
		t.Fatalf("unmarshal ollama fixture: %v", err)
	}
	if fixture.BaseURL == "" {
		t.Fatal("ollama offline fixture must include a base_url so Config treats Ollama as configured")
	}

	cfg := Config{
		OllamaBaseURL:    fixture.BaseURL,
		ActiveModel:      fixture.ActiveModel,
		ExplorationModel: fixture.ExplorationModel,
	}
	if !cfg.configuredProviders()[ProviderOllama] {
		t.Fatal("Ollama base_url should make ProviderOllama configured")
	}
	if got := cfg.resolveActiveModel(fixture.LiveModels); got != ollamaCanonicalModelID(fixture.ActiveModel) {
		t.Errorf("resolveActiveModel = %q, want saved offline Ollama model", got)
	}
	if got := cfg.resolveExplorationModel(fixture.LiveModels); got != ollamaCanonicalModelID(fixture.ExplorationModel) {
		t.Errorf("resolveExplorationModel = %q, want saved offline Ollama model", got)
	}
	a := &App{models: fixture.LiveModels}
	if !a.isOllamaOffline(fixture.ActiveModel) {
		t.Error("model absent from the live model list should be usable as an offline picker stub")
	}
}

func TestOpenRouterFixtureParsesCurrentResponse(t *testing.T) {
	body := readDeploymentAwareCompatibilityFixture(t, "openrouter_models_response.json")
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/models" {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write(body)
	}))
	defer srv.Close()

	models := fetchOpenRouterModelsFrom(fetchOpenRouterOptions{apiKey: "sk-or-fixture", baseURL: srv.URL})
	if len(models) != 2 {
		t.Fatalf("expected 2 OpenRouter models, got %d", len(models))
	}
	if models[0].Provider != ProviderOpenRouter || models[0].ID != "z-ai/glm-4.5-air:free" {
		t.Fatalf("first model = %+v", models[0])
	}
	if models[0].PromptPrice != 0 || models[0].CompletionPrice != 0 {
		t.Errorf("free OpenRouter model prices = %f/%f, want zero", models[0].PromptPrice, models[0].CompletionPrice)
	}
	if models[1].PromptPrice != 3 || models[1].CompletionPrice != 15 {
		t.Errorf("paid OpenRouter prices = %f/%f, want 3/15 per million", models[1].PromptPrice, models[1].CompletionPrice)
	}
}

type compatibilityNativeModelCases struct {
	AmbiguousOldNativeModelIDs   []compatibilityNativeModelCase `json:"ambiguous_old_native_model_ids"`
	UnambiguousOldNativeModelIDs []compatibilityNativeModelCase `json:"unambiguous_old_native_model_ids"`
}

type compatibilityNativeModelCase struct {
	ModelID   string                        `json:"model_id"`
	Offerings []compatibilityNativeOffering `json:"offerings"`
}

type compatibilityNativeOffering struct {
	DeploymentID         string  `json:"deployment_id"`
	Provider             string  `json:"provider"`
	NativeModelID        string  `json:"native_model_id"`
	PromptPricePer1M     float64 `json:"prompt_price_per_1m"`
	CompletionPricePer1M float64 `json:"completion_price_per_1m"`
}

func compatibilityLegacyProviderForDeployment(provider string) string {
	switch provider {
	case "anthropic", "anthropic-bedrock", "anthropic-vertex":
		return ProviderAnthropic
	case "openai", "openai-azure":
		return ProviderOpenAI
	case "gemini", "gemini-vertex":
		return ProviderGemini
	case "grok":
		return ProviderGrok
	case "openrouter":
		return ProviderOpenRouter
	case "ollama":
		return ProviderOllama
	default:
		return provider
	}
}

func compatibilityOfferingsToModels(offerings []compatibilityNativeOffering) []ModelDef {
	models := make([]ModelDef, 0, len(offerings))
	for _, offering := range offerings {
		if offering.DeploymentID == "" {
			continue
		}
		models = append(models, ModelDef{
			Provider:        compatibilityLegacyProviderForDeployment(offering.Provider),
			ID:              offering.NativeModelID,
			PromptPrice:     offering.PromptPricePer1M,
			CompletionPrice: offering.CompletionPricePer1M,
		})
	}
	return models
}

func TestOldNativeModelCostFallbackIsExplicitForAmbiguousIDs(t *testing.T) {
	var fixture compatibilityNativeModelCases
	if err := json.Unmarshal(readDeploymentAwareCompatibilityFixture(t, "old_native_model_cases.json"), &fixture); err != nil {
		t.Fatalf("unmarshal native model fixture: %v", err)
	}
	if len(fixture.AmbiguousOldNativeModelIDs) == 0 || len(fixture.UnambiguousOldNativeModelIDs) == 0 {
		t.Fatal("native model fixture must include ambiguous and unambiguous cases")
	}

	usage := types.Usage{InputTokens: 1000, OutputTokens: 500}
	for _, ambiguous := range fixture.AmbiguousOldNativeModelIDs {
		models := compatibilityOfferingsToModels(ambiguous.Offerings)
		if len(models) < 2 {
			t.Fatalf("ambiguous case %q produced %d models, want at least 2", ambiguous.ModelID, len(models))
		}
		got := computeCostResult(computeCostOptions{models: models, modelID: ambiguous.ModelID, usage: usage})
		if got.Status != types.CostStatusUnknown {
			t.Errorf("ambiguous computeCostResult(%q).Status = %q, want unknown", ambiguous.ModelID, got.Status)
		}
		if len(got.MissingDimensions) != 1 || !strings.HasPrefix(got.MissingDimensions[0], "ambiguous_model_id:") {
			t.Errorf("ambiguous computeCostResult(%q).MissingDimensions = %+v", ambiguous.ModelID, got.MissingDimensions)
		}
	}

	for _, unambiguous := range fixture.UnambiguousOldNativeModelIDs {
		models := compatibilityOfferingsToModels(unambiguous.Offerings)
		if len(models) != 1 {
			t.Fatalf("unambiguous case %q produced %d models, want 1", unambiguous.ModelID, len(models))
		}
		got := computeCost(computeCostOptions{models: models, modelID: unambiguous.ModelID, usage: usage})
		want := (1000*models[0].PromptPrice + 500*models[0].CompletionPrice) / 1_000_000
		if math.Abs(got-want) > 1e-12 {
			t.Errorf("unambiguous computeCost(%q) = %f, want %f", unambiguous.ModelID, got, want)
		}
	}
}

func TestAzureMappingsFixtureConfiguresDeploymentAvailability(t *testing.T) {
	var raw struct {
		ConfigVersion int    `json:"config_version"`
		ActiveModel   string `json:"active_model"`
		Deployments   map[string]struct {
			ModelMappings map[string]string `json:"model_mappings"`
		} `json:"deployments"`
	}
	data := readDeploymentAwareCompatibilityFixture(t, "azure_mappings_config_v2_draft.json")
	if err := json.Unmarshal(data, &raw); err != nil {
		t.Fatalf("unmarshal azure fixture: %v", err)
	}
	if raw.ConfigVersion != 2 {
		t.Fatalf("ConfigVersion = %d, want 2", raw.ConfigVersion)
	}
	if got := raw.Deployments["openai-azure"].ModelMappings["openai/gpt-4.1-2025-04-14"]; got != "my-gpt-4-1-prod" {
		t.Fatalf("azure mapping = %q", got)
	}

	var cfg Config
	if err := json.Unmarshal(data, &cfg); err != nil {
		t.Fatalf("current Config should ignore unknown v2 deployment fields: %v", err)
	}
	if cfg.ActiveModel != raw.ActiveModel {
		t.Errorf("ActiveModel = %q, want %q", cfg.ActiveModel, raw.ActiveModel)
	}
	if !cfg.configuredProviders()[ProviderOpenAI] {
		t.Errorf("Config should derive OpenAI availability from openai-azure deployment mappings: %+v", cfg.configuredProviders())
	}
}
