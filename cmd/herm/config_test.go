package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestLoadConfigCreatesDefault(t *testing.T) {
	dir := t.TempDir()

	cfg, err := loadConfigFrom(dir)
	if err != nil {
		t.Fatalf("loadConfigFrom: %v", err)
	}

	if !reflect.DeepEqual(cfg, defaultConfig()) {
		t.Errorf("config = %+v, want %+v", cfg, defaultConfig())
	}

	// File should exist on disk
	data, err := os.ReadFile(filepath.Join(dir, configDir, configFile))
	if err != nil {
		t.Fatalf("config file not created: %v", err)
	}

	var ondisk Config
	if err := json.Unmarshal(data, &ondisk); err != nil {
		t.Fatalf("unmarshal on-disk config: %v", err)
	}
	if !reflect.DeepEqual(ondisk, defaultConfig()) {
		t.Errorf("on-disk config = %+v, want %+v", ondisk, defaultConfig())
	}
}

func TestLoadConfigRoundTrip(t *testing.T) {
	dir := t.TempDir()

	original := Config{ConfigVersion: hermConfigVersionDeploymentAware, PasteCollapseMinChars: 10}
	if err := saveConfigTo(saveConfigToOptions{dir: dir, cfg: original}); err != nil {
		t.Fatalf("saveConfigTo: %v", err)
	}

	loaded, err := loadConfigFrom(dir)
	if err != nil {
		t.Fatalf("loadConfigFrom: %v", err)
	}

	if !reflect.DeepEqual(loaded, original) {
		t.Errorf("loaded = %+v, want %+v", loaded, original)
	}
}

func TestLoadConfigRoundTripWithOllamaURL(t *testing.T) {
	dir := t.TempDir()

	original := Config{OllamaBaseURL: "http://localhost:11434"}
	if err := saveConfigTo(saveConfigToOptions{dir: dir, cfg: original}); err != nil {
		t.Fatalf("saveConfigTo: %v", err)
	}

	loaded, err := loadConfigFrom(dir)
	if err != nil {
		t.Fatalf("loadConfigFrom: %v", err)
	}

	if loaded.OllamaBaseURL != original.OllamaBaseURL {
		t.Errorf("OllamaBaseURL = %q, want %q", loaded.OllamaBaseURL, original.OllamaBaseURL)
	}
}

func TestLoadConfigMissingFileFallback(t *testing.T) {
	dir := t.TempDir()

	// Don't create any file — loadConfigFrom should create defaults
	cfg, err := loadConfigFrom(dir)
	if err != nil {
		t.Fatalf("loadConfigFrom: %v", err)
	}

	if !reflect.DeepEqual(cfg, defaultConfig()) {
		t.Errorf("config = %+v, want defaults %+v", cfg, defaultConfig())
	}
}

func TestLoadConfigMalformedJSON(t *testing.T) {
	dir := t.TempDir()

	cfgDir := filepath.Join(dir, configDir)
	if err := os.MkdirAll(cfgDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(cfgDir, configFile), []byte("{bad json}"), 0o644); err != nil {
		t.Fatal(err)
	}

	cfg, err := loadConfigFrom(dir)
	if err != nil {
		t.Fatalf("loadConfigFrom: %v", err)
	}

	if !reflect.DeepEqual(cfg, defaultConfig()) {
		t.Errorf("config = %+v, want defaults %+v on malformed JSON", cfg, defaultConfig())
	}
}

func TestLoadConfigMergesNewFields(t *testing.T) {
	dir := t.TempDir()

	// Write a config file that is missing the PasteCollapseMinChars field
	// (simulates upgrading when a new field is added)
	cfgDir := filepath.Join(dir, configDir)
	if err := os.MkdirAll(cfgDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(cfgDir, configFile), []byte(`{}`), 0o644); err != nil {
		t.Fatal(err)
	}

	cfg, err := loadConfigFrom(dir)
	if err != nil {
		t.Fatalf("loadConfigFrom: %v", err)
	}

	// Missing field should get its default value
	if cfg.PasteCollapseMinChars != defaultConfig().PasteCollapseMinChars {
		t.Errorf("PasteCollapseMinChars = %d, want default %d",
			cfg.PasteCollapseMinChars, defaultConfig().PasteCollapseMinChars)
	}
}

func TestSortPrefsRoundTrip(t *testing.T) {
	dir := t.TempDir()

	cfg := Config{
		PasteCollapseMinChars: 200,
		ModelSortCol:          "price",
		ModelSortDirs: map[string]bool{
			"name": true, "provider": true, "price": false, "context": true,
		},
	}
	if err := saveConfigTo(saveConfigToOptions{dir: dir, cfg: cfg}); err != nil {
		t.Fatalf("saveConfigTo: %v", err)
	}

	loaded, err := loadConfigFrom(dir)
	if err != nil {
		t.Fatalf("loadConfigFrom: %v", err)
	}

	if loaded.ModelSortCol != "price" {
		t.Errorf("ModelSortCol = %q, want %q", loaded.ModelSortCol, "price")
	}
	if loaded.ModelSortDirs["price"] != false {
		t.Error("ModelSortDirs[price] = true, want false (descending)")
	}
	if loaded.ModelSortDirs["name"] != true {
		t.Error("ModelSortDirs[name] = false, want true (ascending)")
	}
}

func TestSortPrefsDefaultsWhenMissing(t *testing.T) {
	dir := t.TempDir()

	cfg := Config{PasteCollapseMinChars: 200}
	if err := saveConfigTo(saveConfigToOptions{dir: dir, cfg: cfg}); err != nil {
		t.Fatalf("saveConfigTo: %v", err)
	}

	loaded, err := loadConfigFrom(dir)
	if err != nil {
		t.Fatalf("loadConfigFrom: %v", err)
	}

	if loaded.ModelSortCol != "" {
		t.Errorf("ModelSortCol = %q, want empty (default)", loaded.ModelSortCol)
	}
	if loaded.ModelSortDirs != nil {
		t.Errorf("ModelSortDirs = %v, want nil (default)", loaded.ModelSortDirs)
	}
}

func TestSortAscFromMapDefaults(t *testing.T) {
	// nil map → all ascending
	result := sortAscFromMap(nil)
	for i, v := range result {
		if !v {
			t.Errorf("sortAscFromMap(nil)[%d] = false, want true", i)
		}
	}
}

func TestSortAscRoundTrip(t *testing.T) {
	original := [4]bool{true, false, false, true}
	m := sortAscToMap(original)
	restored := sortAscFromMap(m)
	if restored != original {
		t.Errorf("round-trip: got %v, want %v", restored, original)
	}
}

func TestSaveConfigCreatesDir(t *testing.T) {
	dir := t.TempDir()
	subdir := filepath.Join(dir, "nested", "path")

	cfg := Config{PasteCollapseMinChars: 3}
	if err := saveConfigTo(saveConfigToOptions{dir: subdir, cfg: cfg}); err != nil {
		t.Fatalf("saveConfigTo: %v", err)
	}

	// Verify file exists
	data, err := os.ReadFile(filepath.Join(subdir, configDir, configFile))
	if err != nil {
		t.Fatalf("config file not created: %v", err)
	}

	var loaded Config
	if err := json.Unmarshal(data, &loaded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if loaded.PasteCollapseMinChars != 3 {
		t.Errorf("PasteCollapseMinChars = %d, want 3", loaded.PasteCollapseMinChars)
	}
}

func TestSaveConfigWritesDeploymentAwareShape(t *testing.T) {
	dir := t.TempDir()
	cfg := Config{
		OpenRouterAPIKey: "sk-or-legacy",
		Deployments: map[string]DeploymentConfig{
			"openrouter":   {APIKey: "sk-or-v2", BaseURL: "https://openrouter.example"},
			"openai-azure": {APIKey: "az", Endpoint: "https://example.openai.azure.com", APIVersion: "2024-08-01-preview", ModelMappings: map[string]string{"openai/gpt-4.1-2025-04-14": "prod"}},
		},
		Routing: &RoutingPolicy{
			Default: []RoutingStage{{Deployments: []DeploymentChoice{{DeploymentID: "openrouter", Weight: 100}}, Retries: 1}},
		},
	}
	if err := saveConfigTo(saveConfigToOptions{dir: dir, cfg: cfg}); err != nil {
		t.Fatalf("saveConfigTo: %v", err)
	}

	data, err := os.ReadFile(filepath.Join(dir, configDir, configFile))
	if err != nil {
		t.Fatalf("read config: %v", err)
	}
	var raw map[string]any
	if err := json.Unmarshal(data, &raw); err != nil {
		t.Fatalf("Unmarshal: %v", err)
	}
	if raw["config_version"].(float64) != hermConfigVersionDeploymentAware {
		t.Fatalf("config_version = %v", raw["config_version"])
	}
	if _, ok := raw["openrouter_api_key"]; ok {
		t.Fatalf("saved config should not contain legacy openrouter_api_key: %s", data)
	}
	deployments := raw["deployments"].(map[string]any)
	openrouter := deployments["openrouter"].(map[string]any)
	if got := openrouter["api_key"]; got != "sk-or-v2" {
		t.Fatalf("v2 deployment should win over legacy flat key, got %v", got)
	}

	loaded, err := loadConfigFrom(dir)
	if err != nil {
		t.Fatalf("loadConfigFrom: %v", err)
	}
	if loaded.OpenRouterAPIKey != "sk-or-v2" || loaded.Deployments["openrouter"].BaseURL != "https://openrouter.example" {
		t.Fatalf("loaded config did not preserve v2 deployment and backfill runtime field: %+v", loaded)
	}
}

func TestSaveConfigPreservesUnknownCanonicalModels(t *testing.T) {
	dir := t.TempDir()
	cfg := Config{
		ActiveModel:      "openai/newly-refreshed-model",
		ExplorationModel: "z-ai/new-openrouter-only:free",
		Deployments: map[string]DeploymentConfig{
			"openrouter": {APIKey: "sk-or"},
		},
	}
	if err := saveConfigTo(saveConfigToOptions{dir: dir, cfg: cfg}); err != nil {
		t.Fatalf("saveConfigTo: %v", err)
	}
	loaded, err := loadConfigFrom(dir)
	if err != nil {
		t.Fatalf("loadConfigFrom: %v", err)
	}
	if loaded.ActiveModel != cfg.ActiveModel || loaded.ExplorationModel != cfg.ExplorationModel {
		t.Fatalf("canonical model IDs should survive save/load, got active=%q exploration=%q", loaded.ActiveModel, loaded.ExplorationModel)
	}
}

// ─── Project config tests ───

func TestLoadProjectConfigMissingFile(t *testing.T) {
	dir := t.TempDir()
	pc := loadProjectConfig(dir)
	if pc != (ProjectConfig{}) {
		t.Errorf("loadProjectConfig = %+v, want empty", pc)
	}
}

func TestLoadProjectConfigEmptyRepoRoot(t *testing.T) {
	pc := loadProjectConfig("")
	if pc != (ProjectConfig{}) {
		t.Errorf("loadProjectConfig(\"\") = %+v, want empty", pc)
	}
}

func TestLoadProjectConfigMalformedJSON(t *testing.T) {
	dir := t.TempDir()
	cfgDir := filepath.Join(dir, configDir)
	if err := os.MkdirAll(cfgDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(cfgDir, configFile), []byte("{bad}"), 0o644); err != nil {
		t.Fatal(err)
	}
	pc := loadProjectConfig(dir)
	if pc != (ProjectConfig{}) {
		t.Errorf("loadProjectConfig = %+v, want empty on malformed JSON", pc)
	}
}

func TestProjectConfigRoundTrip(t *testing.T) {
	dir := t.TempDir()
	original := ProjectConfig{
		ActiveModel:      "openai/gpt-4",
		Personality:      "concise",
		SubAgentMaxTurns: 10,
	}
	if err := saveProjectConfig(saveProjectConfigOptions{repoRoot: dir, pc: original}); err != nil {
		t.Fatalf("saveProjectConfig: %v", err)
	}
	loaded := loadProjectConfig(dir)
	if loaded != original {
		t.Errorf("loaded = %+v, want %+v", loaded, original)
	}
}

func TestSaveProjectConfigCreatesDir(t *testing.T) {
	dir := t.TempDir()
	subdir := filepath.Join(dir, "nested", "repo")
	pc := ProjectConfig{ActiveModel: "claude-3"}
	if err := saveProjectConfig(saveProjectConfigOptions{repoRoot: subdir, pc: pc}); err != nil {
		t.Fatalf("saveProjectConfig: %v", err)
	}
	loaded := loadProjectConfig(subdir)
	if loaded.ActiveModel != "claude-3" {
		t.Errorf("ActiveModel = %q, want %q", loaded.ActiveModel, "claude-3")
	}
}

func TestMergeConfigsProjectOverrides(t *testing.T) {
	global := Config{
		PasteCollapseMinChars: 200,
		ActiveModel:           "default-model",
		Personality:           "friendly",
		SubAgentMaxTurns:      15,
		AnthropicAPIKey:       "key123",
	}
	project := ProjectConfig{
		ActiveModel:      "project-model",
		SubAgentMaxTurns: 5,
	}
	merged := mergeConfigs(mergeConfigsOptions{global: global, project: project})

	// Overridden fields
	if merged.ActiveModel != "project-model" {
		t.Errorf("ActiveModel = %q, want %q", merged.ActiveModel, "project-model")
	}
	if merged.SubAgentMaxTurns != 5 {
		t.Errorf("SubAgentMaxTurns = %d, want 5", merged.SubAgentMaxTurns)
	}
	// Non-overridden project field falls back to global
	if merged.Personality != "friendly" {
		t.Errorf("Personality = %q, want %q (global fallback)", merged.Personality, "friendly")
	}
	// Global-only fields unchanged
	if merged.PasteCollapseMinChars != 200 {
		t.Errorf("PasteCollapseMinChars = %d, want 200", merged.PasteCollapseMinChars)
	}
	if merged.AnthropicAPIKey != "key123" {
		t.Errorf("AnthropicAPIKey = %q, want %q", merged.AnthropicAPIKey, "key123")
	}
}

func TestMergeConfigsEmptyProject(t *testing.T) {
	global := Config{
		PasteCollapseMinChars: 200,
		ActiveModel:           "default-model",
		Personality:           "friendly",
		SubAgentMaxTurns:      15,
	}
	merged := mergeConfigs(mergeConfigsOptions{global: global, project: ProjectConfig{}})
	if !reflect.DeepEqual(merged, global) {
		t.Errorf("merged = %+v, want %+v (unchanged global)", merged, global)
	}
}

func TestMergeConfigsAllOverridden(t *testing.T) {
	global := Config{
		ActiveModel:      "global-model",
		Personality:      "verbose",
		SubAgentMaxTurns: 15,
	}
	project := ProjectConfig{
		ActiveModel:      "proj-model",
		Personality:      "terse",
		SubAgentMaxTurns: 3,
	}
	merged := mergeConfigs(mergeConfigsOptions{global: global, project: project})
	if merged.ActiveModel != "proj-model" {
		t.Errorf("ActiveModel = %q, want %q", merged.ActiveModel, "proj-model")
	}
	if merged.Personality != "terse" {
		t.Errorf("Personality = %q, want %q", merged.Personality, "terse")
	}
	if merged.SubAgentMaxTurns != 3 {
		t.Errorf("SubAgentMaxTurns = %d, want 3", merged.SubAgentMaxTurns)
	}
}

// ─── Config UI tests ───

func TestCfgTabNamesStructure(t *testing.T) {
	want := []string{"Deployments", "Global", "Project", "Routing"}
	if !reflect.DeepEqual(cfgTabNames, want) {
		t.Errorf("cfgTabNames = %v, want %v", cfgTabNames, want)
	}
}

func TestProjectTabFieldLabels(t *testing.T) {
	a := &App{}
	fields := a.projectTabFields()
	wantLabels := []string{"Active Model", "Exploration Model", "Personality", "Sub-Agent Max Turns", "Thinking"}
	if len(fields) != len(wantLabels) {
		t.Fatalf("projectTabFields returned %d fields, want %d", len(fields), len(wantLabels))
	}
	for i, f := range fields {
		if f.label != wantLabels[i] {
			t.Errorf("field[%d].label = %q, want %q", i, f.label, wantLabels[i])
		}
		if f.globalHint == nil {
			t.Errorf("field[%d] (%s) has nil globalHint", i, f.label)
		}
	}
}

func TestProjectTabFieldGetSet(t *testing.T) {
	a := &App{
		cfgProjectDraft: ProjectConfig{
			ActiveModel:      "test-model",
			ExplorationModel: "explore-model",
			Personality:      "brief",
			SubAgentMaxTurns: 7,
		},
	}
	fields := a.projectTabFields()

	// Verify get returns project values
	if v := fields[0].get(Config{}); v != "test-model" {
		t.Errorf("ActiveModel get = %q, want %q", v, "test-model")
	}
	if v := fields[1].get(Config{}); v != "explore-model" {
		t.Errorf("ExplorationModel get = %q, want %q", v, "explore-model")
	}
	if v := fields[2].get(Config{}); v != "brief" {
		t.Errorf("Personality get = %q, want %q", v, "brief")
	}
	if v := fields[3].get(Config{}); v != "7" {
		t.Errorf("SubAgentMaxTurns get = %q, want %q", v, "7")
	}

	// Verify set modifies project draft
	fields[0].set(nil, "new-model")
	if a.cfgProjectDraft.ActiveModel != "new-model" {
		t.Errorf("after set, ActiveModel = %q, want %q", a.cfgProjectDraft.ActiveModel, "new-model")
	}
	fields[1].set(nil, "new-explore")
	if a.cfgProjectDraft.ExplorationModel != "new-explore" {
		t.Errorf("after set, ExplorationModel = %q, want %q", a.cfgProjectDraft.ExplorationModel, "new-explore")
	}
	fields[2].set(nil, "verbose")
	if a.cfgProjectDraft.Personality != "verbose" {
		t.Errorf("after set, Personality = %q, want %q", a.cfgProjectDraft.Personality, "verbose")
	}
	fields[3].set(nil, "20")
	if a.cfgProjectDraft.SubAgentMaxTurns != 20 {
		t.Errorf("after set, SubAgentMaxTurns = %d, want 20", a.cfgProjectDraft.SubAgentMaxTurns)
	}
}

func TestDeploymentTabFieldsWriteDeploymentConfig(t *testing.T) {
	var cfg Config
	deploymentFieldByLabel(t, cfgAPIKeyFields, "OpenAI API Key").set(&cfg, "sk-openai")
	deploymentFieldByLabel(t, cfgAPIKeyFields, "OpenAI Base URL").set(&cfg, "api.openai.example")
	deploymentFieldByLabel(t, cfgAPIKeyFields, "Azure Model Mappings").set(&cfg, "openai/gpt-4.1-2025-04-14=my-gpt-4-1-prod")

	if got := cfg.Deployments["openai-direct"].APIKey; got != "sk-openai" {
		t.Fatalf("openai-direct api_key = %q", got)
	}
	if got := cfg.Deployments["openai-direct"].BaseURL; got != "http://api.openai.example" {
		t.Fatalf("openai-direct base_url = %q", got)
	}
	if got := cfg.Deployments["openai-azure"].ModelMappings["openai/gpt-4.1-2025-04-14"]; got != "my-gpt-4-1-prod" {
		t.Fatalf("azure mapping = %q", got)
	}
	if cfg.OpenAIAPIKey != "sk-openai" {
		t.Fatalf("deployment tab should update runtime legacy mirror, got %q", cfg.OpenAIAPIKey)
	}
}

func TestDeploymentTabLabelsRemoveDirectFromAnthropicOpenAI(t *testing.T) {
	labels := deploymentFieldLabels(cfgAPIKeyFields)
	for _, label := range []string{"Anthropic API Key", "OpenAI API Key", "Grok API Key", "Gemini API Key", "OpenAI Base URL"} {
		if !stringSliceContains(labels, label) {
			t.Fatalf("deployment fields missing %q in labels: %v", label, labels)
		}
	}
	for _, label := range labels {
		if strings.Contains(label, "Direct") {
			t.Fatalf("deployment field label should not contain Direct: %q in %v", label, labels)
		}
	}
}

func TestDeploymentTabOptionalFieldsGateByCredentials(t *testing.T) {
	clearDeploymentCloudContextEnv(t)

	labels := deploymentFieldLabels(deploymentTabFields(Config{}))
	for _, label := range []string{
		"OpenAI Base URL",
		"Azure OpenAI Endpoint",
		"Azure OpenAI API Version",
		"Azure Model Mappings",
		"Grok Base URL",
		"OpenRouter Base URL",
		"Anthropic Bedrock Region",
		"Anthropic Vertex Project",
		"Anthropic Vertex Region",
		"Gemini Vertex Project",
		"Gemini Vertex Region",
	} {
		if stringSliceContains(labels, label) {
			t.Fatalf("deploymentTabFields without cloud context should hide %q in labels: %v", label, labels)
		}
	}

	openAILabels := deploymentFieldLabels(deploymentTabFields(Config{Deployments: map[string]DeploymentConfig{
		"openai-direct": {APIKey: "sk-openai"},
	}}))
	if !stringSliceContains(openAILabels, "OpenAI Base URL") {
		t.Fatalf("OpenAI API key should show OpenAI Base URL: %v", openAILabels)
	}
	if got, want := labelIndex(openAILabels, "OpenAI Base URL"), labelIndex(openAILabels, "OpenAI API Key")+1; got != want {
		t.Fatalf("OpenAI Base URL should sit below OpenAI API Key, labels: %v", openAILabels)
	}

	grokLabels := deploymentFieldLabels(deploymentTabFields(Config{Deployments: map[string]DeploymentConfig{
		"grok-direct": {APIKey: "xai-key"},
	}}))
	if got, want := labelIndex(grokLabels, "Grok Base URL"), labelIndex(grokLabels, "Grok API Key")+1; got != want {
		t.Fatalf("Grok Base URL should sit below Grok API Key, labels: %v", grokLabels)
	}

	azureLabels := deploymentFieldLabels(deploymentTabFields(Config{Deployments: map[string]DeploymentConfig{
		"openai-azure": {APIKey: "sk-azure"},
	}}))
	for _, label := range []string{"Azure OpenAI Endpoint", "Azure OpenAI API Version", "Azure Model Mappings"} {
		if !stringSliceContains(azureLabels, label) {
			t.Fatalf("Azure API key should show %q in labels: %v", label, azureLabels)
		}
	}

	cloudOnlyConfigLabels := deploymentFieldLabels(deploymentTabFields(Config{Deployments: map[string]DeploymentConfig{
		"anthropic-bedrock": {Region: "us-east-1"},
		"gemini-vertex":     {ProjectID: "project", Region: "us-central1"},
	}}))
	for _, label := range []string{"Anthropic Bedrock Region", "Gemini Vertex Project"} {
		if stringSliceContains(cloudOnlyConfigLabels, label) {
			t.Fatalf("cloud settings without ambient credentials should hide %q in labels: %v", label, cloudOnlyConfigLabels)
		}
	}
}

func TestDeploymentTabCloudFieldsGateByEnvironment(t *testing.T) {
	clearDeploymentCloudContextEnv(t)
	t.Setenv("AWS_PROFILE", "dev")
	bedrockLabels := deploymentFieldLabels(deploymentTabFields(Config{}))
	if !stringSliceContains(bedrockLabels, "Anthropic Bedrock Region") {
		t.Fatalf("AWS credential environment should show Bedrock region: %v", bedrockLabels)
	}
	if stringSliceContains(bedrockLabels, "Anthropic Vertex Project") {
		t.Fatalf("AWS credential environment should not show Vertex fields: %v", bedrockLabels)
	}

	clearDeploymentCloudContextEnv(t)
	t.Setenv("GOOGLE_APPLICATION_CREDENTIALS", "/tmp/google-creds.json")
	vertexLabels := deploymentFieldLabels(deploymentTabFields(Config{}))
	if !stringSliceContains(vertexLabels, "Gemini Vertex Region") {
		t.Fatalf("Google credential environment should show Vertex fields: %v", vertexLabels)
	}
	if stringSliceContains(vertexLabels, "Anthropic Bedrock Region") {
		t.Fatalf("Google credential environment should not show Bedrock fields: %v", vertexLabels)
	}
}

func TestDeploymentTabClearsBackfilledLegacyCredential(t *testing.T) {
	cfg := normalizeLoadedConfig(Config{Deployments: map[string]DeploymentConfig{
		"openai-direct": {APIKey: "sk-openai"},
	}})
	if cfg.OpenAIAPIKey == "" {
		t.Fatalf("expected runtime legacy mirror to be backfilled")
	}

	deploymentFieldByLabel(t, cfgAPIKeyFields, "OpenAI API Key").set(&cfg, "")
	if cfg.OpenAIAPIKey != "" {
		t.Fatalf("clearing deployment field should clear legacy runtime mirror")
	}
	if cfg.deploymentConfigs()["openai-direct"].APIKey != "" {
		t.Fatalf("cleared deployment should not be rehydrated from legacy field")
	}
	if _, ok := deploymentConfigsForStorage(cfg)["openai-direct"]; ok {
		t.Fatalf("cleared deployment should not be written to storage")
	}
}

func deploymentFieldByLabel(t *testing.T, fields []cfgField, label string) cfgField {
	t.Helper()
	for _, field := range fields {
		if field.label == label {
			return field
		}
	}
	t.Fatalf("deployment field %q not found in labels: %v", label, deploymentFieldLabels(fields))
	return cfgField{}
}

func deploymentFieldLabels(fields []cfgField) []string {
	labels := make([]string, 0, len(fields))
	for _, field := range fields {
		labels = append(labels, field.label)
	}
	return labels
}

func stringSliceContains(values []string, target string) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
}

func labelIndex(values []string, target string) int {
	for i, value := range values {
		if value == target {
			return i
		}
	}
	return -1
}

func clearDeploymentCloudContextEnv(t *testing.T) {
	t.Helper()
	names := []string{"AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_REGION", "VERTEX_PROJECT_ID", "VERTEX_REGION"}
	names = append(names, deploymentBedrockCredentialEnv...)
	names = append(names, deploymentVertexCredentialEnv...)
	for _, name := range names {
		t.Setenv(name, "")
	}
}

func TestRoutingTabHasSelectableActions(t *testing.T) {
	models := []ModelDef{{
		Provider:      ProviderOpenAI,
		OwnerProvider: ProviderOpenAI,
		ID:            "openai/gpt-4.1-2025-04-14",
		Deployments: []ModelDeploymentDef{
			{DeploymentID: "openai-direct"},
			{DeploymentID: "openrouter"},
		},
	}}
	one := &App{
		cfgTab: cfgTabRouting,
		cfgDraft: Config{Deployments: map[string]DeploymentConfig{
			"openai-direct": {APIKey: "sk"},
		}},
		models: models,
	}
	fields := one.routingTabFields()
	if len(fields) != 1 || fields[0].label != "Add rule" || fields[0].action == nil {
		t.Fatalf("routing tab should expose only Add rule for empty routing: %+v", fields)
	}
	rows := one.buildConfigRows()
	if !rowsContain(rows, "Set custom routing, per provider or model (advanced).") {
		t.Fatalf("routing intro missing: %v", rows)
	}
	if rowsContain(rows, "Route syntax:") {
		t.Fatalf("routing mini-language help should not be shown: %v", rows)
	}

	two := &App{
		cfgTab: cfgTabRouting,
		cfgDraft: Config{
			ActiveModel: "openai/gpt-4.1-2025-04-14",
			Deployments: map[string]DeploymentConfig{
				"openai-direct": {APIKey: "sk"},
				"openrouter":    {APIKey: "sk-or"},
			},
		},
		models: models,
	}
	fields = two.routingTabFields()
	if len(fields) != 1 || fields[0].label != "Add rule" {
		t.Fatalf("two deployments should expose Add rule action, got fields: %+v", fields)
	}

	two.cfgDraft.Routing = &RoutingPolicy{Models: map[string][]RoutingStage{
		"anthropic/claude-sonnet-4-20250514": {{Deployments: []DeploymentChoice{{DeploymentID: "openrouter", Weight: 100}}}},
	}}
	if !two.routingControlsVisible(two.cfgDraft) {
		t.Fatalf("existing routing should still be recognized as routing-aware")
	}
	fields = two.routingTabFields()
	if len(fields) != 2 || fields[1].label != "Model anthropic/claude-sonnet-4-20250514" || fields[1].action == nil {
		t.Fatalf("existing model route should be selectable, got fields: %+v", fields)
	}
	rows = two.buildConfigRows()
	if !rowsContain(rows, "Model anthropic/claude-sonnet-4-20250514") {
		t.Fatalf("existing model route should be summarized: %v", rows)
	}
	if rowsContain(rows, "Delete rule") {
		t.Fatalf("delete should be contextual to selected rules, not shown on main routing page: %v", rows)
	}
}

func TestProjectTabSubAgentClearsOnEmpty(t *testing.T) {
	a := &App{cfgProjectDraft: ProjectConfig{SubAgentMaxTurns: 10}}
	fields := a.projectTabFields()
	fields[3].set(nil, "") // Sub-Agent Max Turns is at index 3 now
	if a.cfgProjectDraft.SubAgentMaxTurns != 0 {
		t.Errorf("SubAgentMaxTurns = %d, want 0 after clearing", a.cfgProjectDraft.SubAgentMaxTurns)
	}
}

func TestBuildConfigRowsNoProject(t *testing.T) {
	a := &App{
		cfgTab:   cfgTabProject,
		repoRoot: "",
	}
	rows := a.buildConfigRows()
	joined := strings.Join(rows, "\n")
	found := false
	for _, row := range rows {
		if strings.Contains(row, "No project detected") {
			found = true
			break
		}
	}
	if !found {
		t.Errorf("buildConfigRows on Project tab with no repo should contain 'No project detected', got %v", rows)
	}
	if strings.Contains(joined, "↑/↓=select") || strings.Contains(joined, "Enter=") || strings.Contains(joined, "Ctrl+S=save") {
		t.Errorf("no-project footer should only expose tab/close actions, got %v", rows)
	}
	if strings.Contains(joined, "Overriding global config for current project") {
		t.Errorf("no-project rows should not show project override copy, got %v", rows)
	}
}

func TestBuildConfigRowsGlobalHint(t *testing.T) {
	a := &App{
		cfgTab:          cfgTabProject,
		repoRoot:        "/some/repo",
		cfgDraft:        Config{ActiveModel: "global-model", Personality: "friendly"},
		cfgProjectDraft: ProjectConfig{}, // no overrides
	}
	rows := a.buildConfigRows()
	foundModel := false
	foundPersonality := false
	for _, row := range rows {
		if strings.Contains(row, "(global: global-model)") {
			foundModel = true
		}
		if strings.Contains(row, "(global: friendly)") {
			foundPersonality = true
		}
	}
	if !foundModel {
		t.Error("expected '(global: global-model)' hint for unoverridden Active Model")
	}
	if !foundPersonality {
		t.Error("expected '(global: friendly)' hint for unoverridden Personality")
	}
	if !rowsContain(rows, "Overriding global config for current project (/some/repo).") {
		t.Fatalf("project rows missing project path intro: %v", rows)
	}
}

func TestBuildConfigRowsProjectOverrideShown(t *testing.T) {
	a := &App{
		cfgTab:          cfgTabProject,
		repoRoot:        "/some/repo",
		cfgDraft:        Config{ActiveModel: "global-model"},
		cfgProjectDraft: ProjectConfig{ActiveModel: "project-model"},
	}
	rows := a.buildConfigRows()
	found := false
	for _, row := range rows {
		if strings.Contains(row, "project-model") && !strings.Contains(row, "global:") {
			found = true
			break
		}
	}
	if !found {
		t.Error("expected project override 'project-model' shown without global hint")
	}
}

func TestBuildConfigRowsDeploymentsOmitsEffectiveProvider(t *testing.T) {
	a := &App{
		cfgTab:          cfgTabDeployments,
		cfgDraft:        Config{ActiveModel: "openai-global", OpenAIAPIKey: "sk-openai"},
		cfgProjectDraft: ProjectConfig{ActiveModel: "openai-project"},
		models: []ModelDef{
			{Provider: ProviderOpenAI, ID: "openai-global"},
			{Provider: ProviderOpenAI, ID: "openai-project"},
		},
	}

	rows := a.buildConfigRows()
	for _, row := range rows {
		if strings.Contains(row, "Effective provider:") {
			t.Fatalf("deployments tab should not show effective provider row, got: %v", rows)
		}
	}
}

func TestBuildConfigRowsDeploymentValueStyling(t *testing.T) {
	a := &App{
		cfgTab: cfgTabDeployments,
		cfgDraft: Config{Deployments: map[string]DeploymentConfig{
			"openai-direct": {APIKey: "sk-openai-secret"},
		}},
		cfgCursor: 0,
	}

	rows := a.buildConfigRows()
	joined := strings.Join(rows, "\n")
	if !strings.Contains(joined, "\033[2m(not set)\033[0m") {
		t.Fatalf("unset deployment values should be dimmed, got:\n%s", joined)
	}
	if !strings.Contains(joined, "OpenAI API Key: \033[1;33msk-o...cret\033[0m") {
		t.Fatalf("configured secret values should be emphasized more than labels, got:\n%s", joined)
	}
	if strings.Contains(joined, "\033[2mOpenAI API Key:") {
		t.Fatalf("configured field labels should not be dimmed, got:\n%s", joined)
	}
	if !strings.Contains(joined, "\033[2m(optional)\033[0m") {
		t.Fatalf("optional deployment values should render as optional, got:\n%s", joined)
	}

	for _, row := range rows {
		plain := ansiEscRe.ReplaceAllString(row, "")
		if strings.Contains(plain, "OpenAI Base URL:") {
			if !strings.HasPrefix(plain, "  OpenAI Base URL:") {
				t.Fatalf("optional deployment setting should be indented, got %q", plain)
			}
			return
		}
	}
	t.Fatalf("OpenAI Base URL row not found: %v", rows)
}

func TestEnterConfigModeSetsPreferredAPIKeyCursorFromEffectiveProvider(t *testing.T) {
	cases := []struct {
		name      string
		provider  string
		modelID   string
		configure func(*Config)
	}{
		{name: "anthropic", provider: ProviderAnthropic, modelID: "anthropic-model", configure: func(c *Config) { c.AnthropicAPIKey = "k" }},
		{name: "openai", provider: ProviderOpenAI, modelID: "openai-model", configure: func(c *Config) { c.OpenAIAPIKey = "k" }},
		{name: "grok", provider: ProviderGrok, modelID: "grok-model", configure: func(c *Config) { c.GrokAPIKey = "k" }},
		{name: "gemini", provider: ProviderGemini, modelID: "gemini-model", configure: func(c *Config) { c.GeminiAPIKey = "k" }},
		{name: "ollama", provider: ProviderOllama, modelID: "ollama-model", configure: func(c *Config) { c.OllamaBaseURL = "http://localhost:11434" }},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			cfg := Config{ActiveModel: tc.modelID}
			tc.configure(&cfg)

			a := &App{
				config: cfg,
				models: []ModelDef{
					{Provider: tc.provider, ID: tc.modelID},
				},
			}

			a.enterConfigMode()

			want := apiKeyRowForProvider(tc.provider)
			if a.cfgCursor != want {
				t.Fatalf("cfgCursor = %d, want %d", a.cfgCursor, want)
			}
			if a.cfgTabCursor[cfgTabDeployments] != want {
				t.Fatalf("cfgTabCursor[cfgTabDeployments] = %d, want %d", a.cfgTabCursor[cfgTabDeployments], want)
			}
		})
	}
}

func TestExitConfigModeSavesBothConfigs(t *testing.T) {
	globalDir := t.TempDir()
	repoDir := t.TempDir()

	a := &App{
		cfgDraft: Config{
			PasteCollapseMinChars: 300,
			Personality:           "global-personality",
		},
		cfgProjectDraft: ProjectConfig{
			ActiveModel: "project-model",
			Personality: "project-personality",
		},
		repoRoot: repoDir,
		resultCh: make(chan any, 16),
	}

	// We can't easily test exitConfigMode because it calls saveConfig which
	// uses the real home dir. Instead test that saveProjectConfig is called
	// by verifying the project config is saved to repoRoot.
	a.projectConfig = a.cfgProjectDraft
	if err := saveProjectConfig(saveProjectConfigOptions{repoRoot: a.repoRoot, pc: a.projectConfig}); err != nil {
		t.Fatalf("saveProjectConfig: %v", err)
	}

	loaded := loadProjectConfig(repoDir)
	if loaded.ActiveModel != "project-model" {
		t.Errorf("ActiveModel = %q, want %q", loaded.ActiveModel, "project-model")
	}
	if loaded.Personality != "project-personality" {
		t.Errorf("Personality = %q, want %q", loaded.Personality, "project-personality")
	}

	// Also verify global config can be saved independently
	if err := saveConfigTo(saveConfigToOptions{dir: globalDir, cfg: a.cfgDraft}); err != nil {
		t.Fatalf("saveConfigTo: %v", err)
	}
	globalLoaded, err := loadConfigFrom(globalDir)
	if err != nil {
		t.Fatalf("loadConfigFrom: %v", err)
	}
	if globalLoaded.Personality != "global-personality" {
		t.Errorf("global Personality = %q, want %q", globalLoaded.Personality, "global-personality")
	}
}

// --- ExplorationModel tests ---

func explorationTestModels() []ModelDef {
	return []ModelDef{
		{Provider: ProviderAnthropic, ID: "claude-sonnet"},
		{Provider: ProviderAnthropic, ID: "claude-haiku"},
		{Provider: ProviderOpenAI, ID: "gpt-4o"},
	}
}

func TestResolveExplorationModel_FallsBackToActive(t *testing.T) {
	cfg := Config{
		AnthropicAPIKey: "key",
		ActiveModel:     "claude-sonnet",
		// ExplorationModel is empty
	}
	got := cfg.resolveExplorationModel(explorationTestModels())
	if got != "claude-sonnet" {
		t.Errorf("resolveExplorationModel = %q, want %q (should fall back to active)", got, "claude-sonnet")
	}
}

func TestResolveExplorationModel_UsesConfigured(t *testing.T) {
	cfg := Config{
		AnthropicAPIKey:  "key",
		ActiveModel:      "claude-sonnet",
		ExplorationModel: "claude-haiku",
	}
	got := cfg.resolveExplorationModel(explorationTestModels())
	if got != "claude-haiku" {
		t.Errorf("resolveExplorationModel = %q, want %q", got, "claude-haiku")
	}
}

func TestResolveExplorationModel_InvalidFallsBack(t *testing.T) {
	cfg := Config{
		AnthropicAPIKey:  "key",
		ActiveModel:      "claude-sonnet",
		ExplorationModel: "nonexistent-model",
	}
	got := cfg.resolveExplorationModel(explorationTestModels())
	if got != "claude-sonnet" {
		t.Errorf("resolveExplorationModel = %q, want %q (should fall back for invalid model)", got, "claude-sonnet")
	}
}

func TestResolveExplorationModel_NoKeyForProvider(t *testing.T) {
	cfg := Config{
		AnthropicAPIKey:  "key",
		ActiveModel:      "claude-sonnet",
		ExplorationModel: "gpt-4o", // valid model but no OpenAI key
	}
	got := cfg.resolveExplorationModel(explorationTestModels())
	// gpt-4o provider has no key, so it's not in available models — falls back
	if got != "claude-sonnet" {
		t.Errorf("resolveExplorationModel = %q, want %q (no key for exploration model provider)", got, "claude-sonnet")
	}
}

func TestMergeConfigsExplorationModel(t *testing.T) {
	global := Config{
		ActiveModel:      "claude-sonnet",
		ExplorationModel: "claude-haiku",
	}
	project := ProjectConfig{
		ExplorationModel: "gpt-4o",
	}
	merged := mergeConfigs(mergeConfigsOptions{global: global, project: project})
	if merged.ExplorationModel != "gpt-4o" {
		t.Errorf("merged ExplorationModel = %q, want %q", merged.ExplorationModel, "gpt-4o")
	}
}

func TestMergeConfigsExplorationModelEmpty(t *testing.T) {
	global := Config{
		ExplorationModel: "claude-haiku",
	}
	project := ProjectConfig{} // empty — should not override
	merged := mergeConfigs(mergeConfigsOptions{global: global, project: project})
	if merged.ExplorationModel != "claude-haiku" {
		t.Errorf("merged ExplorationModel = %q, want %q (empty project should not override)", merged.ExplorationModel, "claude-haiku")
	}
}

// --- Smart model defaults tests ---

// defaultTestModels includes the exact model IDs from the default maps so
// we can test that preferredDefault picks them correctly.
func defaultTestModels() []ModelDef {
	return []ModelDef{
		{Provider: ProviderAnthropic, ID: "claude-sonnet-4-6"},
		{Provider: ProviderAnthropic, ID: "claude-haiku-4-5"},
		{Provider: ProviderAnthropic, ID: "claude-opus-4-6"},
		{Provider: ProviderAnthropic, ID: "claude-opus-4-7"},
		{Provider: ProviderOpenAI, ID: "gpt-4.1-2025-04-14"},
		{Provider: ProviderOpenAI, ID: "gpt-4.1-mini-2025-04-14"},
		{Provider: ProviderGrok, ID: "grok-3"},
		{Provider: ProviderGrok, ID: "grok-3-mini"},
		{Provider: ProviderGemini, ID: "gemini-2.5-pro"},
		{Provider: ProviderGemini, ID: "gemini-2.5-flash"},
	}
}

func TestResolveActiveModel_DefaultsToSonnet(t *testing.T) {
	cfg := Config{AnthropicAPIKey: "key"} // no ActiveModel set
	got := cfg.resolveActiveModel(defaultTestModels())
	if got != "claude-sonnet-4-6" {
		t.Errorf("resolveActiveModel = %q, want %q", got, "claude-sonnet-4-6")
	}
}

func TestResolveExplorationModel_DefaultsToHaiku(t *testing.T) {
	cfg := Config{
		AnthropicAPIKey: "key",
		// no ActiveModel, no ExplorationModel
	}
	got := cfg.resolveExplorationModel(defaultTestModels())
	if got != "claude-haiku-4-5" {
		t.Errorf("resolveExplorationModel = %q, want %q (should default to haiku, not active model)", got, "claude-haiku-4-5")
	}
}

func TestResolveActiveModel_DefaultNotInCatalog(t *testing.T) {
	// Models list does NOT include the default IDs — should fall back to first available
	models := []ModelDef{
		{Provider: ProviderAnthropic, ID: "claude-old-model"},
		{Provider: ProviderAnthropic, ID: "claude-other-model"},
	}
	cfg := Config{AnthropicAPIKey: "key"}
	got := cfg.resolveActiveModel(models)
	if got != "claude-old-model" {
		t.Errorf("resolveActiveModel = %q, want %q (fallback to first available)", got, "claude-old-model")
	}
}

func TestResolveExplorationModel_DefaultNotInCatalog(t *testing.T) {
	// Models list does NOT include haiku — should fall back to active model
	models := []ModelDef{
		{Provider: ProviderAnthropic, ID: "claude-sonnet-4-6"},
	}
	cfg := Config{AnthropicAPIKey: "key"}
	got := cfg.resolveExplorationModel(models)
	// No haiku in catalog, falls back to resolveActiveModel → claude-sonnet-4-6
	if got != "claude-sonnet-4-6" {
		t.Errorf("resolveExplorationModel = %q, want %q (fallback when default not in catalog)", got, "claude-sonnet-4-6")
	}
}

func TestResolveActiveModel_OpenAIDefaults(t *testing.T) {
	cfg := Config{OpenAIAPIKey: "key"} // no ActiveModel set
	got := cfg.resolveActiveModel(defaultTestModels())
	if got != "gpt-4.1-2025-04-14" {
		t.Errorf("resolveActiveModel = %q, want %q", got, "gpt-4.1-2025-04-14")
	}
}

func TestResolveExplorationModel_OpenAIDefaults(t *testing.T) {
	cfg := Config{OpenAIAPIKey: "key"}
	got := cfg.resolveExplorationModel(defaultTestModels())
	if got != "gpt-4.1-mini-2025-04-14" {
		t.Errorf("resolveExplorationModel = %q, want %q", got, "gpt-4.1-mini-2025-04-14")
	}
}

// --- Ollama offline model persistence tests ---

// Arbitrary Ollama model IDs used across offline tests.
// The actual names don't matter — they just need to look like Ollama model IDs.
const (
	testOllamaActiveModel  = "test-active:latest"
	testOllamaExploreModel = "test-explore:latest"
	testOllamaOtherModel   = "test-other:latest"
	testOllamaURL          = "http://localhost:11434"
)

func TestResolveActiveModel_OllamaOfflineTrustsSaved(t *testing.T) {
	// Ollama URL configured, but no Ollama models in the live list (offline).
	// The saved model should be returned as-is.
	cfg := Config{
		OllamaBaseURL: testOllamaURL,
		ActiveModel:   testOllamaActiveModel,
	}
	got := cfg.resolveActiveModel(nil) // no live models
	if got != ollamaCanonicalModelID(testOllamaActiveModel) {
		t.Errorf("resolveActiveModel = %q, want canonical Ollama model for %q", got, testOllamaActiveModel)
	}
}

func TestResolveActiveModel_OllamaOfflineWithOtherProviders(t *testing.T) {
	// Ollama offline but another provider is online — saved Ollama model should still win.
	cfg := Config{
		AnthropicAPIKey: "key",
		OllamaBaseURL:   testOllamaURL,
		ActiveModel:     testOllamaActiveModel,
	}
	got := cfg.resolveActiveModel(nil) // Ollama offline, no live models
	if got != ollamaCanonicalModelID(testOllamaActiveModel) {
		t.Errorf("resolveActiveModel = %q, want canonical Ollama model for %q", got, testOllamaActiveModel)
	}
}

func TestResolveActiveModel_OllamaOnlineUsesLiveModel(t *testing.T) {
	// Ollama is online — live model list includes the saved model.
	cfg := Config{
		OllamaBaseURL: testOllamaURL,
		ActiveModel:   testOllamaActiveModel,
	}
	models := []ModelDef{
		{Provider: ProviderOllama, ID: testOllamaActiveModel},
		{Provider: ProviderOllama, ID: testOllamaOtherModel},
	}
	got := cfg.resolveActiveModel(models)
	if got != testOllamaActiveModel {
		t.Errorf("resolveActiveModel = %q, want %q", got, testOllamaActiveModel)
	}
}

func TestResolveActiveModel_NoOllamaURLNoFallback(t *testing.T) {
	// No Ollama URL — unknown model should NOT be trusted, falls back to available.
	cfg := Config{
		AnthropicAPIKey: "key",
		ActiveModel:     testOllamaActiveModel, // not in catalog, no Ollama URL
	}
	got := cfg.resolveActiveModel(nil)
	if got == testOllamaActiveModel {
		t.Errorf("resolveActiveModel = %q, should not trust unknown model when no Ollama URL configured", got)
	}
}

func TestResolveExplorationModel_OllamaOfflineTrustsSaved(t *testing.T) {
	cfg := Config{
		OllamaBaseURL:    testOllamaURL,
		ActiveModel:      testOllamaActiveModel,
		ExplorationModel: testOllamaExploreModel,
	}
	got := cfg.resolveExplorationModel(nil)
	if got != ollamaCanonicalModelID(testOllamaExploreModel) {
		t.Errorf("resolveExplorationModel = %q, want canonical Ollama model for %q", got, testOllamaExploreModel)
	}
}

func TestOllamaModelProvider_InLiveList(t *testing.T) {
	models := []ModelDef{
		{Provider: ProviderOllama, ID: testOllamaActiveModel},
		{Provider: ProviderOllama, ID: testOllamaOtherModel},
	}
	got := ollamaModelProvider(ollamaModelProviderOptions{modelID: testOllamaActiveModel, models: models, ollamaURL: testOllamaURL})
	if got != ProviderOllama {
		t.Errorf("ollamaModelProvider = %q, want %q", got, ProviderOllama)
	}
}

func TestOllamaModelProvider_NotInListWithURL(t *testing.T) {
	// Model not in live list but Ollama URL is set — assume Ollama.
	got := ollamaModelProvider(ollamaModelProviderOptions{modelID: testOllamaActiveModel, models: nil, ollamaURL: testOllamaURL})
	if got != ProviderOllama {
		t.Errorf("ollamaModelProvider = %q, want %q", got, ProviderOllama)
	}
}

func TestOllamaModelProvider_NotInListNoURL(t *testing.T) {
	// No Ollama URL — unknown model returns empty provider.
	got := ollamaModelProvider(ollamaModelProviderOptions{modelID: testOllamaActiveModel, models: nil, ollamaURL: ""})
	if got != "" {
		t.Errorf("ollamaModelProvider = %q, want empty string", got)
	}
}

// --- isOllamaOffline tests ---

func TestIsOllamaOffline_ModelInLiveList(t *testing.T) {
	a := &App{
		models: []ModelDef{
			{Provider: ProviderOllama, ID: testOllamaActiveModel},
		},
		cfgDraft: Config{OllamaBaseURL: testOllamaURL},
	}
	if a.isOllamaOffline(testOllamaActiveModel) {
		t.Error("isOllamaOffline = true, want false (model is in live list)")
	}
}

func TestIsOllamaOffline_ModelNotInLiveList(t *testing.T) {
	a := &App{
		models:   []ModelDef{}, // Ollama offline — empty live list
		cfgDraft: Config{OllamaBaseURL: testOllamaURL},
	}
	if !a.isOllamaOffline(testOllamaActiveModel) {
		t.Error("isOllamaOffline = false, want true (model not in live list)")
	}
}

func TestIsOllamaOffline_KnownCatalogModel(t *testing.T) {
	// A model that exists in the catalog under a different provider is not offline Ollama.
	a := &App{
		models: []ModelDef{
			{Provider: ProviderAnthropic, ID: "claude-sonnet"},
		},
		cfgDraft: Config{OllamaBaseURL: testOllamaURL},
	}
	if a.isOllamaOffline("claude-sonnet") {
		t.Error("isOllamaOffline = true, want false (model is a known catalog model)")
	}
}

func TestIsOllamaOffline_EmptyModelID(t *testing.T) {
	a := &App{cfgDraft: Config{OllamaBaseURL: testOllamaURL}}
	if a.isOllamaOffline("") {
		t.Error("isOllamaOffline = true, want false for empty model ID")
	}
}

// --- Picker stub tests ---

func TestPickerStubHasCleanID(t *testing.T) {
	// When Ollama is offline, the stub injected into the picker must have
	// the original model ID (not mangled with "(offline)") so selection works.
	a := &App{
		models: []ModelDef{},
		cfgDraft: Config{
			OllamaBaseURL: testOllamaURL,
			ActiveModel:   testOllamaActiveModel,
		},
		resultCh: make(chan any, 16),
	}

	var selected string
	a.doOpenConfigModelPicker(doOpenConfigModelPickerOptions{
		models:       []ModelDef{},
		getCurrentID: func() string { return testOllamaActiveModel },
		onSelect:     func(id string) { selected = id },
	})

	// Find the stub in menuModels
	var stub *ModelDef
	for i, m := range a.menuModels {
		if m.Provider == ProviderOllama {
			stub = &a.menuModels[i]
			break
		}
	}
	if stub == nil {
		t.Fatal("expected an Ollama stub in menuModels, got none")
	}
	if stub.ID != testOllamaActiveModel {
		t.Errorf("stub.ID = %q, want %q (ID must be clean, not mangled)", stub.ID, testOllamaActiveModel)
	}
	if stub.Label == "" || stub.Label == testOllamaActiveModel {
		t.Errorf("stub.Label = %q, want label with '(offline)' suffix", stub.Label)
	}

	// Simulate selecting the stub — onSelect should receive the clean ID
	a.menuAction(a.menuCursor)
	if selected != testOllamaActiveModel {
		t.Errorf("onSelect received %q, want %q (clean ID)", selected, testOllamaActiveModel)
	}
}

// --- Ollama URL normalization tests ---

func TestOllamaURLNormalization(t *testing.T) {
	field := deploymentFieldByLabel(t, cfgAPIKeyFields, "Ollama Base URL")

	cases := []struct {
		input string
		want  string
	}{
		{"http://localhost:11434", "http://localhost:11434"},         // already correct
		{"https://ollama.example.com", "https://ollama.example.com"}, // https preserved
		{"localhost:11434", "http://localhost:11434"},                // bare host gets http://
		{"  localhost:11434  ", "http://localhost:11434"},            // whitespace trimmed
		{"", ""},   // empty cleared
		{"  ", ""}, // whitespace-only cleared
	}

	for _, tc := range cases {
		var cfg Config
		field.set(&cfg, tc.input)
		if got := cfg.deploymentConfigs()["ollama-local"].BaseURL; got != tc.want {
			t.Errorf("set(%q): Ollama BaseURL = %q, want %q", tc.input, got, tc.want)
		}
	}
}

func TestMergeConfigsThinking(t *testing.T) {
	// nil → no override
	global := Config{}
	project := ProjectConfig{}
	merged := mergeConfigs(mergeConfigsOptions{global: global, project: project})
	if merged.Thinking != nil {
		t.Error("nil project Thinking should not override global")
	}

	// Explicit true overrides nil global
	trueVal := true
	project.Thinking = &trueVal
	merged = mergeConfigs(mergeConfigsOptions{global: global, project: project})
	if merged.Thinking == nil || !*merged.Thinking {
		t.Error("project Thinking=true should override global nil")
	}

	// Explicit false overrides global true
	global.Thinking = &trueVal
	falseVal := false
	project.Thinking = &falseVal
	merged = mergeConfigs(mergeConfigsOptions{global: global, project: project})
	if merged.Thinking == nil || *merged.Thinking {
		t.Error("project Thinking=false should override global true")
	}
}

func TestEffectiveThinking(t *testing.T) {
	c := Config{}
	if c.effectiveThinking() {
		t.Error("nil Thinking should default to false")
	}

	trueVal := true
	c.Thinking = &trueVal
	if !c.effectiveThinking() {
		t.Error("Thinking=true should return true")
	}

	falseVal := false
	c.Thinking = &falseVal
	if c.effectiveThinking() {
		t.Error("Thinking=false should return false")
	}
}

func rowsContain(rows []string, needle string) bool {
	for _, row := range rows {
		if strings.Contains(row, needle) {
			return true
		}
	}
	return false
}

func TestConfigThinkingRoundTrip(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.json")

	// Save config with Thinking=true
	trueVal := true
	cfg := Config{Thinking: &trueVal}
	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if err := os.WriteFile(path, data, 0644); err != nil {
		t.Fatalf("write: %v", err)
	}

	// Load it back
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	var loaded Config
	if err := json.Unmarshal(raw, &loaded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if loaded.Thinking == nil || !*loaded.Thinking {
		t.Errorf("round-trip: Thinking = %v, want true", loaded.Thinking)
	}
}
