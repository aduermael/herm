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

func TestMaskKey(t *testing.T) {
	cases := []struct {
		key  string
		want string
	}{
		{"", "(not set)"},
		{"a", "*"},
		{"ab", "**"},
		{"abc", "a...c"},
		{"abcd", "a...d"},
		{"abcde", "ab...de"},
		{"abcdefgh", "ab...gh"},
		{"123456789", "1234...6789"},
		{"sk-openai-secret", "sk-o...cret"},
	}
	for _, tc := range cases {
		if got := maskKey(tc.key); got != tc.want {
			t.Errorf("maskKey(%q) = %q, want %q", tc.key, got, tc.want)
		}
	}
}

func TestSecretEditDisplay(t *testing.T) {
	cases := []struct {
		val  string
		want string
	}{
		{"", ""},
		{"a", "*"},
		{"abc", "***"},
		{"abcdef", "******"},
		{"abcdefg", "ab***fg"},
		{"abcdefghijkl", "ab********kl"},
		{"abcdefghijklmnop", "abcd********mnop"},
	}
	for _, tc := range cases {
		if got := secretEditDisplay(tc.val); got != tc.want {
			t.Errorf("secretEditDisplay(%q) = %q, want %q", tc.val, got, tc.want)
		}
	}
}

func TestDeploymentTabFieldsWriteDeploymentConfig(t *testing.T) {
	var cfg Config
	deploymentFieldByLabel(t, cfgAPIKeyFields, "OpenAI API Key").set(&cfg, "sk-openai")
	deploymentFieldByLabel(t, cfgAPIKeyFields, "Azure Model Mappings").set(&cfg, "openai/gpt-4.1-2025-04-14=my-gpt-4-1-prod")

	if got := cfg.Deployments["openai-direct"].APIKey; got != "sk-openai" {
		t.Fatalf("openai-direct api_key = %q", got)
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
	for _, label := range []string{"Anthropic API Key", "OpenAI API Key", "Grok API Key", "Gemini API Key"} {
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
		"Azure OpenAI Endpoint",
		"Azure OpenAI API Version",
		"Azure Model Mappings",
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
		cfgTab:   cfgTabProject,
		repoRoot: "/some/repo",
		cfgDraft: Config{
			ActiveModel: "global-model",
			Deployments: map[string]DeploymentConfig{"openrouter": {APIKey: "sk-test"}},
		},
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
			"openai-azure":  {APIKey: "sk-azure-secret"},
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
		if strings.Contains(plain, "Azure OpenAI Endpoint:") {
			if !strings.HasPrefix(plain, "  Azure OpenAI Endpoint:") {
				t.Fatalf("optional deployment setting should be indented, got %q", plain)
			}
			return
		}
	}
	t.Fatalf("Azure OpenAI Endpoint row not found: %v", rows)
}

func TestDeleteClearsSecretField(t *testing.T) {
	a := &App{
		cfgTab:   cfgTabDeployments,
		cfgDraft: Config{Deployments: map[string]DeploymentConfig{"openai-direct": {APIKey: "sk-old"}}},
	}
	fields := a.cfgCurrentFields()
	idx := -1
	for i, f := range fields {
		if f.secret {
			idx = i
			break
		}
	}
	if idx < 0 {
		t.Fatal("no secret field found")
	}
	a.cfgCursor = idx
	a.cfgEditing = true
	a.cfgEditBuf = []rune("sk-new-key-to-replace")
	a.cfgEditCursor = 5

	seq := csiSequence{params: []byte("3"), final: '~'}
	a.handleConfigEditCSISequence(handleConfigEditCSISequenceOptions{seq: seq, readByte: nil})

	if len(a.cfgEditBuf) != 0 {
		t.Fatalf("Delete should clear secret field buffer, got %q", string(a.cfgEditBuf))
	}
	if a.cfgEditCursor != 0 {
		t.Fatalf("cursor should be 0 after Delete on secret field, got %d", a.cfgEditCursor)
	}
}

func newSecretFieldApp() *App {
	a := &App{
		cfgTab:   cfgTabDeployments,
		cfgDraft: Config{Deployments: map[string]DeploymentConfig{"openai-direct": {APIKey: "sk-old"}}},
	}
	fields := a.cfgCurrentFields()
	idx := -1
	for i, f := range fields {
		if f.secret {
			idx = i
			break
		}
	}
	if idx < 0 {
		panic("no secret field found")
	}
	a.cfgCursor = idx
	a.cfgEditing = true
	a.cfgEditBuf = []rune("sk-new-key-to-replace")
	a.cfgEditCursor = 5
	return a
}

func TestCtrlUClearsSecretField(t *testing.T) {
	a := newSecretFieldApp()
	a.handleConfigEditByte(handleConfigEditByteOptions{ch: 0x15})
	if len(a.cfgEditBuf) != 0 {
		t.Fatalf("Ctrl+U should clear secret field buffer, got %q", string(a.cfgEditBuf))
	}
	if a.cfgEditCursor != 0 {
		t.Fatalf("cursor should be 0 after Ctrl+U on secret field, got %d", a.cfgEditCursor)
	}
}

func TestCtrlKClearsSecretField(t *testing.T) {
	a := newSecretFieldApp()
	a.handleConfigEditByte(handleConfigEditByteOptions{ch: 0x0b})
	if len(a.cfgEditBuf) != 0 {
		t.Fatalf("Ctrl+K should clear secret field buffer, got %q", string(a.cfgEditBuf))
	}
	if a.cfgEditCursor != 0 {
		t.Fatalf("cursor should be 0 after Ctrl+K on secret field, got %d", a.cfgEditCursor)
	}
}

func TestCtrlWClearsSecretField(t *testing.T) {
	a := newSecretFieldApp()
	a.handleConfigEditByte(handleConfigEditByteOptions{ch: 0x17})
	if len(a.cfgEditBuf) != 0 {
		t.Fatalf("Ctrl+W should clear secret field buffer, got %q", string(a.cfgEditBuf))
	}
	if a.cfgEditCursor != 0 {
		t.Fatalf("cursor should be 0 after Ctrl+W on secret field, got %d", a.cfgEditCursor)
	}
}

func TestEnterConfigModeClearsStaleProjectModelsWhenNoProviders(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	repoRoot := t.TempDir()

	app := &App{
		repoRoot: repoRoot,
		globalConfig: Config{
			ActiveModel:      "orphan/global-active",
			ExplorationModel: "orphan/global-explore",
		},
		projectConfig: ProjectConfig{
			ActiveModel:      "anthropic/claude-opus-4-6",
			ExplorationModel: "anthropic/claude-haiku-4-5",
			Personality:      "kept",
		},
		models:   defaultTestModels(),
		resultCh: make(chan any, 8),
		headless: true,
	}

	app.enterConfigMode()
	app.stopConfigTicker()

	if app.cfgDraft.ActiveModel != "" || app.cfgDraft.ExplorationModel != "" {
		t.Fatalf("global draft models = %q/%q, want cleared", app.cfgDraft.ActiveModel, app.cfgDraft.ExplorationModel)
	}
	if app.cfgProjectDraft.ActiveModel != "" || app.cfgProjectDraft.ExplorationModel != "" {
		t.Fatalf("project draft models = %q/%q, want cleared", app.cfgProjectDraft.ActiveModel, app.cfgProjectDraft.ExplorationModel)
	}
	if app.cfgProjectDraft.Personality != "kept" {
		t.Fatalf("Personality = %q, want unrelated project fields preserved", app.cfgProjectDraft.Personality)
	}

	app.cfgDraft.Deployments = map[string]DeploymentConfig{"openrouter": {APIKey: "sk-test"}}
	app.exitConfigMode(true)

	if app.projectConfig.ActiveModel != "" || app.projectConfig.ExplorationModel != "" {
		t.Fatalf("saved project models = %q/%q, want cleared after adding provider", app.projectConfig.ActiveModel, app.projectConfig.ExplorationModel)
	}
	if app.projectConfig.Personality != "kept" {
		t.Fatalf("saved Personality = %q, want preserved", app.projectConfig.Personality)
	}
	if modelsReadyForAgent(app.projectModelConfig()) {
		t.Fatal("modelsReadyForAgent should be false so user gets Select Active Model hint")
	}
	if !configNeedsModelSelection(app.projectModelConfig()) {
		t.Fatal("configNeedsModelSelection should be true after adding provider without explicit model")
	}
}

// TestEnterConfigModeDoesNotLeakRoutingEditsBeforeSave guards against the
// config-draft aliasing issue: routing is edited in place (setRoutingStages),
// so without deep-cloning Routing on entry, draft edits mutate the live
// globalConfig even when the user never saves.
func TestEnterConfigModeDoesNotLeakRoutingEditsBeforeSave(t *testing.T) {
	t.Setenv("HOME", t.TempDir())

	app := &App{
		repoRoot: t.TempDir(),
		globalConfig: Config{
			AnthropicAPIKey: "sk-test",
			Routing: &RoutingPolicy{
				Default: []RoutingStage{{Deployments: []DeploymentChoice{{DeploymentID: "anthropic"}}}},
			},
		},
		models:   defaultTestModels(),
		resultCh: make(chan any, 8),
		headless: true,
	}

	app.enterConfigMode()
	app.stopConfigTicker()

	// Edit routing in the draft only (no save).
	setRoutingStages(setRoutingStagesOptions{
		cfg:    &app.cfgDraft,
		scope:  routingScopeModel,
		key:    "openrouter/some-model",
		stages: []RoutingStage{{Deployments: []DeploymentChoice{{DeploymentID: "openrouter"}}}},
	})

	// The live config must be untouched until exitConfigMode(save=true).
	if app.globalConfig.Routing == nil {
		t.Fatal("globalConfig.Routing became nil after a draft-only edit")
	}
	if len(app.globalConfig.Routing.Models) != 0 {
		t.Fatalf("draft routing edit leaked into globalConfig.Routing.Models = %v", app.globalConfig.Routing.Models)
	}
	// The draft itself should reflect the edit.
	if app.cfgDraft.Routing == nil || len(app.cfgDraft.Routing.Models["openrouter/some-model"]) == 0 {
		t.Fatal("draft routing edit was not applied to cfgDraft")
	}
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

func TestResolveExplorationModel_DefaultsToActiveWhenUnset(t *testing.T) {
	cfg := Config{
		AnthropicAPIKey: "key",
		// no ActiveModel, no ExplorationModel
	}
	got := cfg.resolveExplorationModel(defaultTestModels())
	if got != "claude-sonnet-4-6" {
		t.Errorf("resolveExplorationModel = %q, want %q (unset exploration uses active resolution)", got, "claude-sonnet-4-6")
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
	if got != "gpt-4.1-2025-04-14" {
		t.Errorf("resolveExplorationModel = %q, want %q (unset exploration uses active resolution)", got, "gpt-4.1-2025-04-14")
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

func TestResolveActiveModel_TrustsOpenRouterNativeModelNotInCatalog(t *testing.T) {
	cfg := Config{
		Deployments: map[string]DeploymentConfig{
			"openrouter": {APIKey: "sk-or"},
		},
		ActiveModel: "minimax/minimax-m2.5:free",
	}
	result := cfg.resolveActiveModelResult(nil)
	if result.Status != configuredModelUsable || result.Fallback {
		t.Fatalf("resolveActiveModelResult = %+v, want usable trusted OpenRouter native model", result)
	}
	if result.ResolvedModelID != "minimax/minimax-m2.5:free" {
		t.Fatalf("ResolvedModelID = %q, want configured OpenRouter model ID", result.ResolvedModelID)
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

func TestConfigSavedMessagesUseDistinctModelAndAPIKeyNotices(t *testing.T) {
	msgs := configSavedMessages(map[string]string{
		"Project Active Model":      "updated",
		"Project Exploration Model": "saved",
		"OpenRouter API Key":        "saved",
	})

	if len(msgs) != 3 {
		t.Fatalf("message count = %d, want 3", len(msgs))
	}

	contents := make([]string, len(msgs))
	for i, msg := range msgs {
		if len(msg.inlineBlocks) != 1 {
			t.Fatalf("message %d inline blocks = %d, want 1", i, len(msg.inlineBlocks))
		}
		contents[i] = msg.content
	}

	if contents[0] != "OpenRouter API Key saved." {
		t.Fatalf("first message = %q, want API key notice first (sorted)", contents[0])
	}
	if contents[1] != "Project Active Model updated." {
		t.Fatalf("active model message = %q", contents[1])
	}
	if contents[2] != "Project Exploration Model saved." {
		t.Fatalf("exploration model message = %q", contents[2])
	}

	activeStyle := msgs[1].inlineBlocks[0].text
	exploreStyle := msgs[2].inlineBlocks[0].text
	apiStyle := msgs[0].inlineBlocks[0].text

	if activeStyle == exploreStyle || activeStyle == apiStyle || exploreStyle == apiStyle {
		t.Fatalf("notices should use distinct colors:\nactive=%q\nexplore=%q\napi=%q", activeStyle, exploreStyle, apiStyle)
	}
	if !strings.Contains(activeStyle, styleChatDimYellow) {
		t.Fatalf("active model updated style = %q, want dim yellow on full notice", activeStyle)
	}
	if !strings.Contains(exploreStyle, styleChatDimGreen) {
		t.Fatalf("exploration model saved style = %q, want dim green on full notice", exploreStyle)
	}
	if !strings.Contains(apiStyle, styleChatGreen) {
		t.Fatalf("api key style = %q, want green italic accent", apiStyle)
	}
}

func TestConfigSavedMessagesUseProjectThemeOpacity(t *testing.T) {
	cases := []struct {
		label     string
		direction string
	}{
		{"Active Model", "saved"},
		{"Active Model", "updated"},
		{"Active Model", "removed"},
		{"Exploration Model", "saved"},
		{"Exploration Model", "updated"},
		{"Exploration Model", "removed"},
		{"OpenRouter API Key", "saved"},
		{"OpenRouter API Key", "updated"},
		{"OpenRouter API Key", "removed"},
		{"Personality", "saved"},
		{"Personality", "updated"},
		{"Personality", "removed"},
	}
	for _, tc := range cases {
		style := configChangeNoticeFor(configChangeNoticeForOptions{label: tc.label, direction: tc.direction}).style
		if !strings.HasSuffix(style, ";3m") {
			t.Errorf("%s %s style = %q, want chat accent (;3m italic)", tc.label, tc.direction, style)
		}
		if strings.Contains(style, ";1") || strings.Contains(style, ";2m") {
			t.Errorf("%s %s uses bold/dim luminosity: %q", tc.label, tc.direction, style)
		}
		if strings.Contains(style, "\033[9") {
			t.Errorf("%s %s uses bright ANSI color: %q", tc.label, tc.direction, style)
		}
	}
	emptyStyle := configSavedMessages(nil)[0].inlineBlocks[0].text
	if !strings.Contains(emptyStyle, styleChatMuted) {
		t.Fatalf("empty save style = %q, want muted italic accent", emptyStyle)
	}
}

func TestConfigSavedMessagesGenericSettingsUseRedForRemoved(t *testing.T) {
	msgs := configSavedMessages(map[string]string{
		"Personality": "updated",
		"Thinking":    "removed",
	})

	if len(msgs) != 2 {
		t.Fatalf("message count = %d, want 2", len(msgs))
	}
	if msgs[0].content != "Personality updated." {
		t.Fatalf("updated message = %q", msgs[0].content)
	}
	if msgs[1].content != "Thinking removed." {
		t.Fatalf("removed message = %q", msgs[1].content)
	}
	if !strings.Contains(msgs[0].inlineBlocks[0].text, styleChatDimYellow) {
		t.Fatalf("updated style = %q, want dim yellow italic accent", msgs[0].inlineBlocks[0].text)
	}
	if !strings.Contains(msgs[1].inlineBlocks[0].text, styleChatRed) {
		t.Fatalf("removed style = %q, want red italic accent", msgs[1].inlineBlocks[0].text)
	}
}

func TestConfigSavedMessagesEachPurposeUsesDistinctColors(t *testing.T) {
	cases := []struct {
		label     string
		direction string
		wantStyle string
	}{
		{"Active Model", "saved", styleChatDimGreen},
		{"Active Model", "updated", styleChatDimYellow},
		{"Exploration Model", "saved", styleChatDimGreen},
		{"Exploration Model", "updated", styleChatDimYellow},
		{"OpenRouter API Key", "saved", styleChatGreen},
		{"OpenRouter API Key", "updated", styleChatDimYellow},
		{"Personality", "saved", styleChatBlue},
		{"Personality", "updated", styleChatDimYellow},
	}
	for _, tc := range cases {
		notice := configChangeNoticeFor(configChangeNoticeForOptions{label: tc.label, direction: tc.direction})
		if notice.style != tc.wantStyle {
			t.Errorf("%s %s style = %q, want %q", tc.label, tc.direction, notice.style, tc.wantStyle)
		}
	}
	for _, label := range []string{"Active Model", "Exploration Model"} {
		notice := configChangeNoticeFor(configChangeNoticeForOptions{label: label, direction: "removed"})
		if notice.style != styleChatDimRed {
			t.Errorf("%s unset style = %q, want dim red on full notice", label, notice.style)
		}
	}
	for _, label := range []string{"OpenRouter API Key", "Personality"} {
		notice := configChangeNoticeFor(configChangeNoticeForOptions{label: label, direction: "removed"})
		if notice.style != styleChatRed {
			t.Errorf("%s removed style = %q, want red italic accent", label, notice.style)
		}
	}
	for _, tc := range []struct {
		label   string
		content string
	}{
		{"Active Model", "Active Model unset."},
		{"Exploration Model", "Exploration Model unset."},
		{"Project Exploration Model", "Project Exploration Model unset."},
	} {
		notice := configChangeNoticeFor(configChangeNoticeForOptions{label: tc.label, direction: uiConfigChangeRemoved})
		if notice.content != tc.content {
			t.Errorf("%s removed content = %q, want %q", tc.label, notice.content, tc.content)
		}
	}

	empty := configSavedMessages(nil)
	if len(empty) != 1 || empty[0].content != "Config saved." {
		t.Fatalf("empty save message = %#v", empty)
	}
	if !strings.Contains(empty[0].inlineBlocks[0].text, styleChatMuted) {
		t.Fatalf("empty save style = %q, want muted italic accent", empty[0].inlineBlocks[0].text)
	}
}

func assertMissingModelMessage(t *testing.T, msg chatMessage) {
	t.Helper()
	if msg.kind != msgError {
		t.Fatalf("message kind = %v, want error", msg.kind)
	}
	if msg.content != configMissingModelMessage {
		t.Fatalf("message content = %q, want %q", msg.content, configMissingModelMessage)
	}
}

func assertSelectModelHintMessage(t *testing.T, msg chatMessage) {
	t.Helper()
	if msg.kind != msgInfo {
		t.Fatalf("message kind = %v, want info", msg.kind)
	}
	if msg.content != configSelectModelHintMessage {
		t.Fatalf("message content = %q, want %q", msg.content, configSelectModelHintMessage)
	}
	if !strings.Contains(msg.inlineBlocks[0].text, styleChatBlue) {
		t.Fatalf("hint style = %q, want blue italic accent", msg.inlineBlocks[0].text)
	}
}

func TestConfigSavedMessagesHintAfterAPIKeyWhenNoActiveModel(t *testing.T) {
	cfg := Config{Deployments: map[string]DeploymentConfig{"openrouter": {APIKey: "sk-test"}}}
	msgs := configSavedMessagesWithHints(configSavedMessagesWithHintsOptions{
		changed: map[string]string{"OpenRouter API Key": "saved"},
		cfg:     cfg,
		project: ProjectConfig{},
	})

	if len(msgs) != 2 {
		t.Fatalf("message count = %d, want 2", len(msgs))
	}
	if msgs[0].content != "OpenRouter API Key saved." {
		t.Fatalf("first message = %q", msgs[0].content)
	}
	assertSelectModelHintMessage(t, msgs[1])
}

func TestConfigSavedMessagesNoHintWhenActiveModelSet(t *testing.T) {
	cfg := Config{
		ActiveModel: "openrouter/test",
		Deployments: map[string]DeploymentConfig{"openrouter": {APIKey: "sk-test"}},
	}
	msgs := configSavedMessagesWithHints(configSavedMessagesWithHintsOptions{
		changed: map[string]string{"OpenRouter API Key": "saved"},
		cfg:     cfg,
		project: ProjectConfig{},
	})
	if len(msgs) != 1 {
		t.Fatalf("message count = %d, want 1", len(msgs))
	}
}

func TestConfigSavedMessagesNoHintWhenAPIKeyUpdated(t *testing.T) {
	cfg := Config{
		Deployments: map[string]DeploymentConfig{"openrouter": {APIKey: "sk-test"}},
	}
	msgs := configSavedMessagesWithHints(configSavedMessagesWithHintsOptions{
		changed: map[string]string{"OpenRouter API Key": "updated"},
		cfg:     cfg,
		project: ProjectConfig{},
	})
	if len(msgs) != 2 {
		t.Fatalf("message count = %d, want save notice + hint", len(msgs))
	}
	if msgs[0].content != "OpenRouter API Key updated." {
		t.Fatalf("first message = %q", msgs[0].content)
	}
	if msgs[1].content != configSelectModelHintMessage {
		t.Fatalf("hint message = %q", msgs[1].content)
	}
	assertSelectModelHintMessage(t, msgs[1])
}

func TestConfigNeedsModelSelection(t *testing.T) {
	cfg := Config{Deployments: map[string]DeploymentConfig{"openrouter": {APIKey: "sk-test"}}}
	if !configNeedsModelSelection(projectModelConfigOptions{global: cfg, project: ProjectConfig{}}) {
		t.Fatal("want hint when provider configured without active model")
	}
	cfg.ActiveModel = "openrouter/test"
	if configNeedsModelSelection(projectModelConfigOptions{global: cfg, project: ProjectConfig{}}) {
		t.Fatal("do not want hint when active model is set (exploration optional)")
	}
	project := ProjectConfig{ActiveModel: "openrouter/test"}
	cfg.ActiveModel = ""
	if configNeedsModelSelection(projectModelConfigOptions{global: cfg, project: project}) {
		t.Fatal("do not want hint when project active model is set")
	}
}

func TestStartAgentRequiresExplicitActiveModel(t *testing.T) {
	app := &App{
		globalConfig: Config{
			Deployments: map[string]DeploymentConfig{"openrouter": {APIKey: "sk-test"}},
		},
		configReady: true,
		models:      defaultTestModels(),
		headless:    true,
		width:       80,
	}
	app.config = mergeConfigs(mergeConfigsOptions{global: app.globalConfig, project: app.projectConfig})

	app.startAgent("hello")
	if app.agent != nil || app.agentRunning {
		t.Fatal("agent should not start without explicit active model")
	}
	found := false
	for _, msg := range app.messages {
		if msg.content == configMissingModelMessage {
			found = true
			assertMissingModelMessage(t, msg)
			break
		}
	}
	if !found {
		t.Fatalf("messages = %v, want missing model error", chatMessageContents(app.messages))
	}
}

func TestHandleEnterShowsMissingModelMessage(t *testing.T) {
	app := &App{
		globalConfig: Config{
			Deployments: map[string]DeploymentConfig{"openrouter": {APIKey: "sk-test"}},
		},
		langdagClient: newTestClient("ok"),
		configReady:   true,
		models:        defaultTestModels(),
		headless:      true,
		width:         80,
	}
	app.config = mergeConfigs(mergeConfigsOptions{global: app.globalConfig, project: app.projectConfig})
	app.setInputValue("hello")

	app.handleEnter()

	if app.agent != nil || app.agentRunning {
		t.Fatal("agent should not start without explicit model")
	}
	foundUser := false
	foundError := false
	for _, msg := range app.messages {
		if msg.kind == msgUser && msg.content == "hello" {
			foundUser = true
		}
		if msg.content == configMissingModelMessage {
			foundError = true
			assertMissingModelMessage(t, msg)
		}
	}
	if !foundUser {
		t.Fatalf("messages = %v, want user message in chat", chatMessageContents(app.messages))
	}
	if !foundError {
		t.Fatalf("messages = %v, want missing model error in chat", chatMessageContents(app.messages))
	}
}

func TestExplicitActiveModelConfigured(t *testing.T) {
	global := Config{ActiveModel: "openrouter/test"}
	if !explicitActiveModelConfigured(projectModelConfigOptions{global: global, project: ProjectConfig{}}) {
		t.Fatal("global active model should count as explicit")
	}
	if explicitActiveModelConfigured(projectModelConfigOptions{global: Config{}, project: ProjectConfig{ActiveModel: "openrouter/test"}}) != true {
		t.Fatal("project active model should count as explicit")
	}
	if explicitActiveModelConfigured(projectModelConfigOptions{global: Config{Deployments: map[string]DeploymentConfig{"openrouter": {APIKey: "sk"}}}, project: ProjectConfig{}}) {
		t.Fatal("API key alone should not count as explicit active model")
	}
}

func TestExplicitExplorationModelConfigured(t *testing.T) {
	global := Config{ExplorationModel: "openrouter/explore"}
	if !explicitExplorationModelConfigured(projectModelConfigOptions{global: global, project: ProjectConfig{}}) {
		t.Fatal("global exploration model should count as explicit")
	}
	if explicitExplorationModelConfigured(projectModelConfigOptions{global: Config{}, project: ProjectConfig{ExplorationModel: "openrouter/explore"}}) != true {
		t.Fatal("project exploration model should count as explicit")
	}
}

func TestModelsReadyForAgent(t *testing.T) {
	if !modelsReadyForAgent(projectModelConfigOptions{global: Config{ActiveModel: "openrouter/test"}, project: ProjectConfig{}}) {
		t.Fatal("explicit active model should be ready")
	}
	if !modelsReadyForAgent(projectModelConfigOptions{global: Config{}, project: ProjectConfig{ExplorationModel: "openrouter/explore"}}) {
		t.Fatal("explicit exploration model should be ready without active model")
	}
	if modelsReadyForAgent(projectModelConfigOptions{global: Config{}, project: ProjectConfig{}}) {
		t.Fatal("no explicit model should not be ready")
	}
}

func TestStartAgentAllowsConfigOverrideActiveModel(t *testing.T) {
	app := &App{
		globalConfig: Config{
			Deployments: map[string]DeploymentConfig{"openrouter": {APIKey: "sk-test"}},
		},
		cliConfigOverrides: `{"active_model":"openrouter/test"}`,
		configReady:        true,
		models:             []ModelDef{{ID: "openrouter/test", Provider: ProviderOpenRouter}},
		langdagClient:      newTestClient("ok"),
		headless:           true,
		width:              80,
	}
	app.rebuildEffectiveConfig()

	if !modelsReadyForAgent(app.effectiveModelConfig()) {
		t.Fatal("config override active model should satisfy explicit-model gate")
	}
	app.startAgent("hello")
	if app.agent == nil || !app.agentRunning {
		t.Fatal("agent should start with config override active model")
	}
	if app.agent.model != "openrouter/test" {
		t.Fatalf("agent model = %q, want override active model", app.agent.model)
	}
}

func TestEffectiveProviderForConfigUsesUncataloguedOpenRouterModel(t *testing.T) {
	app := &App{
		models: []ModelDef{},
	}
	cfg := Config{
		Deployments: map[string]DeploymentConfig{"openrouter": {APIKey: "sk-or"}},
		ActiveModel: "moonshotai/kimi-k2:free",
	}

	provider, modelID := app.effectiveProviderForConfig(cfg)

	if provider != ProviderOpenRouter {
		t.Fatalf("provider = %q, want %q", provider, ProviderOpenRouter)
	}
	if modelID != "moonshotai/kimi-k2:free" {
		t.Fatalf("modelID = %q, want configured OpenRouter native ID", modelID)
	}
}

func TestStartAgentAllowsExplicitExplorationModelOnly(t *testing.T) {
	app := &App{
		globalConfig: Config{
			Deployments: map[string]DeploymentConfig{"openrouter": {APIKey: "sk-test"}},
		},
		projectConfig: ProjectConfig{ExplorationModel: "openrouter/test"},
		configReady:   true,
		models:        []ModelDef{{ID: "openrouter/test", Provider: ProviderOpenRouter}},
		langdagClient: newTestClient("ok"),
		headless:      true,
		width:         80,
	}
	app.config = mergeConfigs(mergeConfigsOptions{global: app.globalConfig, project: app.projectConfig})

	app.startAgent("hello")
	if app.agent == nil || !app.agentRunning {
		t.Fatal("agent should start with explicit exploration model only")
	}
	if app.agent.model != "openrouter/test" {
		t.Fatalf("agent model = %q, want configured exploration model", app.agent.model)
	}
}

func TestDisplayConfiguredModelIDUsesConfiguredWhenFallback(t *testing.T) {
	result := configuredModelResolution{
		ConfiguredModelID: "openrouter/owl-alpha",
		ResolvedModelID:   "openrouter/other",
		Fallback:          true,
	}
	if got := displayConfiguredModelID(displayConfiguredModelIDOptions{result: result, configured: "openrouter/owl-alpha"}); got != "openrouter/owl-alpha" {
		t.Fatalf("displayConfiguredModelID = %q, want configured ID on fallback", got)
	}
}

func TestConfigChangeLabelForProjectTabUsesProjectLabels(t *testing.T) {
	fields := (&App{}).projectTabFields()
	if len(fields) < 2 {
		t.Fatal("expected project tab model fields")
	}
	if got := configChangeLabelForField(configChangeLabelForFieldOptions{field: fields[0], projectTab: true}); got != uiConfigLabelProjectActiveModel {
		t.Fatalf("active model label = %q, want %q", got, uiConfigLabelProjectActiveModel)
	}
	if got := configChangeLabelForField(configChangeLabelForFieldOptions{field: fields[1], projectTab: true}); got != uiConfigLabelProjectExplorationModel {
		t.Fatalf("exploration model label = %q, want %q", got, uiConfigLabelProjectExplorationModel)
	}
	if got := configChangeLabelForField(configChangeLabelForFieldOptions{field: fields[0], projectTab: false}); got != uiConfigLabelActiveModel {
		t.Fatalf("global tab should keep field label = %q", got)
	}
}

func TestGlobalTabBackspaceUnsetsActiveModel(t *testing.T) {
	app := &App{
		cfgActive: true,
		cfgTab:    cfgTabGlobal,
		cfgDraft: Config{
			ActiveModel: "openrouter/bodybuilder",
		},
		cfgChangedLabels: map[string]string{},
		headless:         true,
		width:            80,
	}
	fields := app.settingsTabFields()
	app.cfgCursor = 0
	if fields[0].label != uiConfigLabelActiveModel {
		t.Fatalf("field[0] = %q, want active model", fields[0].label)
	}
	if !app.configFieldSupportsUnset(fields[0]) {
		t.Fatal("global active model should support unset")
	}
	help := strings.Join(app.configHelpRows(), " ")
	if !strings.Contains(help, "Backspace=unset") {
		t.Fatalf("help = %q, want Backspace=unset hint", help)
	}

	app.handleConfigByte(handleConfigByteOptions{ch: 127})

	if app.cfgDraft.ActiveModel != "" {
		t.Fatalf("ActiveModel = %q, want empty after unset", app.cfgDraft.ActiveModel)
	}
	if app.cfgChangedLabels[uiConfigLabelActiveModel] != uiConfigChangeRemoved {
		t.Fatalf("change label = %v, want removed", app.cfgChangedLabels)
	}
}

func TestGlobalTabBackspaceDoesNotUnsetPasteCollapse(t *testing.T) {
	app := &App{
		cfgActive: true,
		cfgTab:    cfgTabGlobal,
		cfgDraft: Config{
			PasteCollapseMinChars: 200,
		},
		headless: true,
		width:    80,
	}
	fields := app.settingsTabFields()
	for i, field := range fields {
		if field.label == "Paste Collapse" {
			app.cfgCursor = i
			break
		}
	}
	field, ok := app.configSelectedField()
	if !ok {
		t.Fatal("expected paste collapse field")
	}
	if app.configFieldSupportsUnset(field) {
		t.Fatal("paste collapse should not support backspace unset on global tab")
	}
	app.handleConfigByte(handleConfigByteOptions{ch: 127})
	if app.cfgDraft.PasteCollapseMinChars != 200 {
		t.Fatalf("PasteCollapseMinChars = %d, want unchanged", app.cfgDraft.PasteCollapseMinChars)
	}
}

func TestShowResolvedModelDisplayShowsConfiguredIDBeforeCatalogLoads(t *testing.T) {
	app := &App{
		globalConfig: Config{
			Deployments: map[string]DeploymentConfig{"openrouter": {APIKey: "sk-or"}},
		},
		projectConfig: ProjectConfig{ActiveModel: "poolside/laguna-xs.2:free"},
		configReady:   true,
		headless:      true,
		width:         80,
	}
	app.config = mergeConfigs(mergeConfigsOptions{global: app.globalConfig, project: app.projectConfig})

	app.showResolvedModelDisplay()
	if len(app.messages) != 1 {
		t.Fatalf("message count = %d, want model display before catalog loads", len(app.messages))
	}
	want := "Using active: poolside/laguna-xs.2:free (project)"
	if app.messages[0].content != want {
		t.Fatalf("display = %q, want %q", app.messages[0].content, want)
	}
}

func TestShowResolvedModelDisplayClearsWhenNoExplicitModel(t *testing.T) {
	app := &App{
		globalConfig: Config{
			Deployments: map[string]DeploymentConfig{"openrouter": {APIKey: "sk-or"}},
		},
		projectConfig: ProjectConfig{ActiveModel: "openrouter/active"},
		configReady:   true,
		models:        []ModelDef{{ID: "openrouter/active", Provider: ProviderOpenRouter}},
		headless:      true,
		width:         80,
	}
	app.config = mergeConfigs(mergeConfigsOptions{global: app.globalConfig, project: app.projectConfig})
	app.showResolvedModelDisplay()
	if len(app.messages) != 1 || !strings.Contains(app.messages[0].content, "Using active:") {
		t.Fatalf("initial display = %v", chatMessageContents(app.messages))
	}

	app.projectConfig.ActiveModel = ""
	app.rebuildEffectiveConfig()
	app.showResolvedModelDisplay()

	found := false
	for _, msg := range app.messages {
		if msg.modelDisplay {
			found = true
			break
		}
	}
	if !found {
		t.Fatalf("model display should remain in chat history after unset, got %v", chatMessageContents(app.messages))
	}
	if app.lastModelDisplayLine != "" {
		t.Fatalf("lastModelDisplayLine = %q, want empty live tracking after unset", app.lastModelDisplayLine)
	}
}

func TestExitConfigModeModelDisplayPreservesHistoryOnUpdate(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	repoRoot := t.TempDir()
	app := &App{
		repoRoot:    repoRoot,
		configReady: true,
		resultCh:    make(chan any, 8),
		headless:    true,
		width:       80,
		globalConfig: Config{
			Deployments: map[string]DeploymentConfig{"openrouter": {APIKey: "sk-or"}},
		},
		cfgDraft: Config{
			Deployments: map[string]DeploymentConfig{"openrouter": {APIKey: "sk-or"}},
		},
		models: []ModelDef{},
	}
	app.config = mergeConfigs(mergeConfigsOptions{global: app.globalConfig, project: app.projectConfig})

	saveModel := func(direction string, modelID string) {
		t.Helper()
		app.cfgActive = true
		if modelID == "" {
			app.cfgProjectDraft = ProjectConfig{}
		} else {
			app.cfgProjectDraft = ProjectConfig{ActiveModel: modelID}
		}
		app.cfgChangedLabels = map[string]string{uiConfigLabelProjectActiveModel: direction}
		app.exitConfigMode(true)
	}

	saveModel(uiConfigChangeSaved, "poolside/laguna-xs.2:free")
	afterSave := chatMessageContents(app.messages)
	if len(afterSave) != 2 || afterSave[0] != "Project Active Model saved." ||
		afterSave[1] != "Using active: poolside/laguna-xs.2:free (project)" {
		t.Fatalf("after save:\n%s", strings.Join(afterSave, "\n"))
	}

	saveModel(uiConfigChangeUpdated, "openrouter/bodybuilder")
	afterUpdate := chatMessageContents(app.messages)
	want := []string{
		"Project Active Model saved.",
		"Using active: poolside/laguna-xs.2:free (project)",
		"Project Active Model updated.",
		"Using active: openrouter/bodybuilder (project)",
	}
	if len(afterUpdate) != len(want) {
		t.Fatalf("after update:\n%s", strings.Join(afterUpdate, "\n"))
	}
	for i, content := range want {
		if afterUpdate[i] != content {
			t.Fatalf("after update[%d] = %q, want %q\nfull:\n%s", i, afterUpdate[i], content, strings.Join(afterUpdate, "\n"))
		}
	}
}

func TestShowResolvedModelDisplayUpdatesProjectActiveModel(t *testing.T) {
	app := &App{
		globalConfig: Config{
			Deployments: map[string]DeploymentConfig{"openrouter": {APIKey: "sk-or"}},
		},
		projectConfig: ProjectConfig{ActiveModel: "openrouter/pareto-code"},
		configReady:   true,
		models:        []ModelDef{},
		headless:      true,
		width:         80,
	}
	app.config = mergeConfigs(mergeConfigsOptions{global: app.globalConfig, project: app.projectConfig})

	app.showResolvedModelDisplay()
	wantFirst := "Using active: openrouter/pareto-code (project)"
	if len(app.messages) != 1 || app.messages[0].content != wantFirst {
		t.Fatalf("first display = %v", chatMessageContents(app.messages))
	}

	app.projectConfig.ActiveModel = "openrouter/other-model"
	app.rebuildEffectiveConfig()
	app.refreshResolvedModelDisplay()

	if len(app.messages) != 1 {
		t.Fatalf("message count = %d, want single model display line", len(app.messages))
	}
	wantSecond := "Using active: openrouter/other-model (project)"
	if app.messages[0].content != wantSecond {
		t.Fatalf("updated display = %q, want %q", app.messages[0].content, wantSecond)
	}
	if !app.messages[0].modelDisplay {
		t.Fatal("expected model display message after update")
	}
}

func TestShowResolvedModelDisplayUpdatesWhenExplorationAdded(t *testing.T) {
	app := &App{
		globalConfig: Config{
			Deployments: map[string]DeploymentConfig{"openrouter": {APIKey: "sk-or"}},
			ActiveModel: "openrouter/active",
		},
		configReady: true,
		models:      []ModelDef{},
		headless:    true,
		width:       80,
	}
	app.config = mergeConfigs(mergeConfigsOptions{global: app.globalConfig, project: app.projectConfig})

	app.showResolvedModelDisplay()
	if len(app.messages) != 1 || !strings.Contains(app.messages[0].content, "Using active: openrouter/active") {
		t.Fatalf("first display = %v", chatMessageContents(app.messages))
	}

	app.globalConfig.ExplorationModel = "openrouter/explore"
	app.rebuildEffectiveConfig()
	app.showResolvedModelDisplay()

	if len(app.messages) != 1 {
		t.Fatalf("message count = %d, want replaced single display line", len(app.messages))
	}
	want := "Using active: openrouter/active (global), exploration: openrouter/explore (global)"
	if app.messages[0].content != want {
		t.Fatalf("updated display = %q, want %q", app.messages[0].content, want)
	}
}

func TestStartupDoesNotShowMissingModelMessage(t *testing.T) {
	app := &App{
		globalConfig: Config{
			Deployments: map[string]DeploymentConfig{"openrouter": {APIKey: "sk-test"}},
		},
		configReady: true,
		models:      []ModelDef{{ID: "openrouter/test", Provider: ProviderOpenRouter}},
		headless:    true,
	}
	app.config = mergeConfigs(mergeConfigsOptions{global: app.globalConfig, project: app.projectConfig})
	app.maybeShowInitialModels()

	for _, msg := range app.messages {
		if msg.content == configMissingModelMessage {
			t.Fatalf("startup should not show missing model message: %v", chatMessageContents(app.messages))
		}
	}
}
