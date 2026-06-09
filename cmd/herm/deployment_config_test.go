package main

import (
	"encoding/json"
	"reflect"
	"testing"
)

func TestDeploymentAwareConfigMigratesLegacyFlatCredentials(t *testing.T) {
	gitCoAuthor := false
	thinking := true
	legacy := Config{
		PasteCollapseMinChars: 200,
		AnthropicAPIKey:       "ant",
		OpenAIAPIKey:          "openai",
		GrokAPIKey:            "xai",
		OpenRouterAPIKey:      "or",
		GeminiAPIKey:          "gemini",
		OllamaBaseURL:         "http://localhost:11434",
		ActiveModel:           "gpt-4.1-2025-04-14",
		ExplorationModel:      "claude-haiku-4-5",
		ModelSortCol:          "price",
		ModelSortDirs:         map[string]bool{"price": false, "name": true},
		SubAgentMaxTurns:      12,
		ExploreMaxTurns:       8,
		GeneralMaxTurns:       20,
		MaxToolIterations:     150,
		MaxAgentDepth:         2,
		Personality:           "concise",
		HistoryMaxEntries:     75,
		GitCoAuthor:           &gitCoAuthor,
		DebugMode:             true,
		Thinking:              &thinking,
	}

	result := migrateDeploymentAwareConfigFromLegacyConfig(DeploymentAwareConfigMigrationOptions{Config: legacy})
	migrated := result.Config
	if migrated.ConfigVersion != hermConfigVersionDeploymentAware {
		t.Fatalf("ConfigVersion = %d", migrated.ConfigVersion)
	}
	if result.ActiveModel.Status != ModelIDMigrationUniqueNative || result.ExplorationModel.Status != ModelIDMigrationUniqueNative {
		t.Fatalf("model migration diagnostics = active:%+v exploration:%+v", result.ActiveModel, result.ExplorationModel)
	}
	if migrated.ActiveModel != "openai/gpt-4.1-2025-04-14" || migrated.ExplorationModel != "anthropic/claude-haiku-4-5" {
		t.Fatalf("models did not migrate to canonical IDs: %+v", migrated)
	}
	if migrated.PasteCollapseMinChars != legacy.PasteCollapseMinChars ||
		migrated.ModelSortCol != legacy.ModelSortCol ||
		!reflect.DeepEqual(migrated.ModelSortDirs, legacy.ModelSortDirs) ||
		migrated.SubAgentMaxTurns != legacy.SubAgentMaxTurns ||
		migrated.ExploreMaxTurns != legacy.ExploreMaxTurns ||
		migrated.GeneralMaxTurns != legacy.GeneralMaxTurns ||
		migrated.MaxToolIterations != legacy.MaxToolIterations ||
		migrated.MaxAgentDepth != legacy.MaxAgentDepth ||
		migrated.Personality != legacy.Personality ||
		migrated.HistoryMaxEntries != legacy.HistoryMaxEntries ||
		!migrated.DebugMode {
		t.Fatalf("non-secret settings did not migrate: %+v", migrated)
	}
	if migrated.GitCoAuthor == nil || *migrated.GitCoAuthor || migrated.Thinking == nil || !*migrated.Thinking {
		t.Fatalf("pointer settings did not migrate: git=%v thinking=%v", migrated.GitCoAuthor, migrated.Thinking)
	}
	tests := map[string]string{
		"anthropic-direct": "ant",
		"openai-direct":    "openai",
		"grok-direct":      "xai",
		"openrouter":       "or",
		"gemini-direct":    "gemini",
	}
	for deploymentID, apiKey := range tests {
		if got := migrated.Deployments[deploymentID].APIKey; got != apiKey {
			t.Errorf("%s APIKey = %q, want %q", deploymentID, got, apiKey)
		}
	}
	if got := migrated.Deployments["ollama-local"].BaseURL; got != legacy.OllamaBaseURL {
		t.Errorf("ollama-local BaseURL = %q, want %q", got, legacy.OllamaBaseURL)
	}
	for _, deploymentID := range []string{"anthropic-direct", "anthropic-bedrock", "anthropic-vertex", "openai-direct", "openai-azure", "gemini-direct", "gemini-vertex", "grok-direct", "openrouter", "ollama-local"} {
		if len(deploymentEnvFallbacks[deploymentID]) == 0 {
			t.Fatalf("missing env fallback metadata for %q", deploymentID)
		}
	}
	data, err := json.Marshal(migrated)
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}
	if containsJSONKey(data, "routing") {
		t.Fatalf("empty routing should be omitted from migrated config JSON: %s", data)
	}
}

func TestDeploymentAwareConfigPreservesV2DeploymentsRoutingAndLetsV2Win(t *testing.T) {
	legacy := Config{
		OpenAIAPIKey: "legacy-openai",
		Deployments: map[string]DeploymentConfig{
			"openai-direct": {
				APIKey:  "v2-openai",
				BaseURL: "https://api.openai.example",
			},
			"openai-azure": {
				APIKey:     "azure-key",
				Endpoint:   "https://example.openai.azure.com",
				APIVersion: "2024-08-01-preview",
				ModelMappings: map[string]string{
					"openai/gpt-4.1-2025-04-14": "my-gpt-4-1-prod",
				},
			},
			"anthropic-bedrock": {Region: "us-east-1"},
			"gemini-vertex":     {ProjectID: "project", Region: "us-central1"},
		},
		Routing: &RoutingPolicy{
			Default: []RoutingStage{{Deployments: []DeploymentChoice{{DeploymentID: "openai-direct", Weight: 100}}, Retries: 1}},
		},
	}

	migrated := deploymentAwareConfigFromLegacyConfig(legacy)
	if got := migrated.Deployments["openai-direct"].APIKey; got != "v2-openai" {
		t.Fatalf("v2 deployment API key should win over legacy flat field, got %q", got)
	}
	if got := migrated.Deployments["openai-direct"].BaseURL; got != "https://api.openai.example" {
		t.Fatalf("base URL not preserved: %q", got)
	}
	if got := migrated.Deployments["openai-azure"].ModelMappings["openai/gpt-4.1-2025-04-14"]; got != "my-gpt-4-1-prod" {
		t.Fatalf("Azure mapping not preserved: %q", got)
	}
	if migrated.Routing == nil || migrated.Routing.Default[0].Retries != 1 {
		t.Fatalf("routing not preserved: %+v", migrated.Routing)
	}
	data, err := json.Marshal(migrated)
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}
	if containsJSONKey(data, "openai_api_key") {
		t.Fatalf("deployment-aware config JSON should not contain legacy flat key: %s", data)
	}
}

func TestDeploymentAwareProjectConfigCannotOverrideDeploymentsOrRouting(t *testing.T) {
	global := DeploymentAwareConfig{
		ConfigVersion:    hermConfigVersionDeploymentAware,
		ActiveModel:      "openai/gpt-4.1-2025-04-14",
		ExplorationModel: "anthropic/claude-haiku-4-5",
		Deployments: map[string]DeploymentConfig{
			"openai-direct": {APIKey: "secret"},
		},
		Routing: &RoutingPolicy{
			Default: []RoutingStage{{Deployments: []DeploymentChoice{{DeploymentID: "openai-direct", Weight: 100}}}},
		},
		Personality:      "global",
		SubAgentMaxTurns: 5,
	}
	projectThinking := true
	project := ProjectConfig{
		ActiveModel:      "anthropic/claude-sonnet-4-20250514",
		ExplorationModel: "openai/gpt-4.1-mini-2025-04-14",
		Personality:      "project",
		SubAgentMaxTurns: 9,
		Thinking:         &projectThinking,
	}

	merged := mergeDeploymentAwareProjectConfig(mergeDeploymentAwareProjectConfigOptions{
		global:  global,
		project: project,
	})
	if merged.ActiveModel != project.ActiveModel || merged.ExplorationModel != project.ExplorationModel {
		t.Fatalf("project model overrides not applied: %+v", merged)
	}
	if merged.Personality != project.Personality || merged.SubAgentMaxTurns != project.SubAgentMaxTurns || merged.Thinking == nil || !*merged.Thinking {
		t.Fatalf("project non-secret overrides not applied: %+v", merged)
	}
	if merged.Deployments["openai-direct"].APIKey != "secret" {
		t.Fatalf("project merge should preserve global deployment credentials: %+v", merged.Deployments)
	}
	if merged.Routing == nil || len(merged.Routing.Default) != 1 {
		t.Fatalf("project merge should preserve global routing: %+v", merged.Routing)
	}
}

func TestRoutingPolicySelectsMostSpecificAuthoritativeRoute(t *testing.T) {
	policy := RoutingPolicy{
		Default: []RoutingStage{{Deployments: []DeploymentChoice{{DeploymentID: "openrouter", Weight: 100}}, Retries: 1}},
		Providers: map[string][]RoutingStage{
			"openai": {{Deployments: []DeploymentChoice{{DeploymentID: "openai-direct", Weight: 100}}, Retries: 2}},
		},
		Models: map[string][]RoutingStage{
			"openai/gpt-4.1-2025-04-14": {{Deployments: []DeploymentChoice{{DeploymentID: "openai-azure", Weight: 100}}, Retries: 3}},
		},
	}

	stages, source, ok := policy.routeFor(routeForOptions{
		canonicalModelID: "openai/gpt-4.1-2025-04-14",
		providerID:       "openai",
	})
	if !ok || source != RouteSourceModel {
		t.Fatalf("model route source = %q/%v", source, ok)
	}
	if len(stages) != 1 || stages[0].Deployments[0].DeploymentID != "openai-azure" || stages[0].Retries != 3 {
		t.Fatalf("model route should not cascade to provider/default stages: %+v", stages)
	}

	stages, source, ok = policy.routeFor(routeForOptions{
		canonicalModelID: "openai/gpt-4.1-mini-2025-04-14",
		providerID:       "openai",
	})
	if !ok || source != RouteSourceProvider {
		t.Fatalf("provider route source = %q/%v", source, ok)
	}
	if len(stages) != 1 || stages[0].Deployments[0].DeploymentID != "openai-direct" {
		t.Fatalf("provider route should not cascade to default stages: %+v", stages)
	}

	aliasPolicy := RoutingPolicy{
		Providers: map[string][]RoutingStage{
			"gemini": {{Deployments: []DeploymentChoice{{DeploymentID: "gemini-direct", Weight: 100}}}},
		},
	}
	stages, source, ok = aliasPolicy.routeFor(routeForOptions{
		canonicalModelID: "google/gemini-2.5-pro",
		providerID:       "google",
	})
	if !ok || source != RouteSourceProvider || stages[0].Deployments[0].DeploymentID != "gemini-direct" {
		t.Fatalf("legacy provider route alias did not resolve for canonical provider: source=%q ok=%v stages=%+v", source, ok, stages)
	}

	stages, source, ok = policy.routeFor(routeForOptions{
		canonicalModelID: "anthropic/claude-sonnet-4-20250514",
		providerID:       "anthropic",
	})
	if !ok || source != RouteSourceDefault {
		t.Fatalf("default route source = %q/%v", source, ok)
	}
	if len(stages) != 1 || stages[0].Deployments[0].DeploymentID != "openrouter" {
		t.Fatalf("default route = %+v", stages)
	}
}

func TestRoutingValidationAcceptsAppleProviderAndDeployment(t *testing.T) {
	policy := RoutingPolicy{
		Providers: map[string][]RoutingStage{
			"apple": {{Deployments: []DeploymentChoice{{DeploymentID: "apple-local", Weight: 100}}}},
		},
		Models: map[string][]RoutingStage{
			"apple/system": {{Deployments: []DeploymentChoice{{DeploymentID: "apple-local", Weight: 100}}}},
		},
	}

	if diagnostics := policy.validate(RoutingValidationIndex{}); len(diagnostics) != 0 {
		t.Fatalf("apple routing diagnostics = %+v, want none", diagnostics)
	}
}

func TestRoutingPolicyReportsValidationDiagnostics(t *testing.T) {
	policy := RoutingPolicy{
		Default: []RoutingStage{{
			Deployments: []DeploymentChoice{
				{DeploymentID: "openai-direct", Weight: 100},
				{DeploymentID: "unknown", Weight: 0},
				{Weight: 1},
			},
			Retries: -1,
		}},
		Providers: map[string][]RoutingStage{
			"unknown-provider": nil,
			"gemini":           {{Deployments: []DeploymentChoice{{DeploymentID: "gemini-direct", Weight: 100}}}},
		},
		Models: map[string][]RoutingStage{
			"not canonical": nil,
			"openai/gpt-4.1-2025-04-14": {{
				Deployments: []DeploymentChoice{{DeploymentID: "openai-azure", Weight: 100}, {DeploymentID: "anthropic-direct", Weight: 100}},
			}},
		},
	}
	known := map[string]bool{"openai-direct": true, "openai-azure": true, "anthropic-direct": true, "gemini-direct": true}
	available := map[string]bool{"openai-direct": true, "anthropic-direct": true, "gemini-direct": true}

	diagnostics := policy.validate(RoutingValidationIndex{
		KnownDeployments:     known,
		AvailableDeployments: available,
		EligibleDeploymentsByModel: map[string]map[string]bool{
			"openai/gpt-4.1-2025-04-14": {"openai-azure": true},
		},
	})
	got := diagnosticPathCodes(diagnostics)
	want := []string{
		"routing.default[0].deployments[1].deployment_id:unknown_deployment",
		"routing.default[0].deployments[1].weight:non_positive_weight",
		"routing.default[0].deployments[2].deployment_id:missing_deployment_id",
		"routing.default[0].retries:negative_retries",
		"routing.models.not canonical:invalid_canonical_model_id",
		"routing.models.openai/gpt-4.1-2025-04-14[0].deployments:no_eligible_deployments",
		"routing.models.openai/gpt-4.1-2025-04-14[0].deployments[0].deployment_id:unavailable_deployment",
		"routing.models.openai/gpt-4.1-2025-04-14[0].deployments[1].deployment_id:ineligible_deployment",
		"routing.providers.unknown-provider:unknown_provider",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("diagnostics = %+v, want %+v\nfull diagnostics: %+v", got, want, diagnostics)
	}
}

func TestRoutingPolicyReportsMissingModelMapping(t *testing.T) {
	policy := RoutingPolicy{
		Models: map[string][]RoutingStage{
			"openai/gpt-4.1-2025-04-14": {{
				Deployments: []DeploymentChoice{{DeploymentID: "openai-azure", Weight: 100}},
			}},
		},
	}

	diagnostics := policy.validate(RoutingValidationIndex{
		KnownDeployments:     map[string]bool{"openai-azure": true},
		AvailableDeployments: map[string]bool{"openai-azure": true},
		EligibleDeploymentsByModel: map[string]map[string]bool{
			"openai/gpt-4.1-2025-04-14": {},
		},
		MissingMappingsByModel: map[string]map[string]bool{
			"openai/gpt-4.1-2025-04-14": {"openai-azure": true},
		},
	})
	got := diagnosticPathCodes(diagnostics)
	want := []string{
		"routing.models.openai/gpt-4.1-2025-04-14[0].deployments:no_eligible_deployments",
		"routing.models.openai/gpt-4.1-2025-04-14[0].deployments[0].deployment_id:missing_model_mapping",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("diagnostics = %+v, want %+v\nfull diagnostics: %+v", got, want, diagnostics)
	}
}

func TestRoutingDiagnosticsReportProviderOverrideIneligibleDeployments(t *testing.T) {
	cfg := Config{
		Deployments: map[string]DeploymentConfig{
			"anthropic-direct": {APIKey: "sk-ant"},
		},
		Routing: &RoutingPolicy{
			Providers: map[string][]RoutingStage{
				"openai": {{Deployments: []DeploymentChoice{{DeploymentID: "anthropic-direct", Weight: 100}}}},
			},
		},
	}
	models := []ModelDef{{
		Provider:      ProviderOpenAI,
		OwnerProvider: ProviderOpenAI,
		ID:            "openai/gpt-4.1-2025-04-14",
		Deployments: []ModelDeploymentDef{{
			DeploymentID: "openai-direct",
		}},
	}}

	diagnostics := routingDiagnosticsForConfigModels(configModelsOptions{cfg: cfg, models: models})
	got := diagnosticPathCodes(diagnostics)
	want := []string{
		"routing.effective.provider.openai/gpt-4.1-2025-04-14[0].deployments:no_eligible_deployments",
		"routing.effective.provider.openai/gpt-4.1-2025-04-14[0].deployments[0].deployment_id:ineligible_deployment",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("diagnostics = %+v, want %+v\nfull diagnostics: %+v", got, want, diagnostics)
	}
}

func TestRoutingStagesParseAndFormatWeightsRetries(t *testing.T) {
	stages, err := parseRoutingStages("openai-direct:70,openai-azure:30@2 | openrouter@1")
	if err != nil {
		t.Fatalf("parseRoutingStages: %v", err)
	}
	if len(stages) != 2 {
		t.Fatalf("stages len = %d", len(stages))
	}
	if stages[0].Retries != 2 || stages[0].Deployments[0].Weight != 70 || stages[0].Deployments[1].DeploymentID != "openai-azure" {
		t.Fatalf("first stage = %+v", stages[0])
	}
	if stages[1].Retries != 1 || stages[1].Deployments[0].Weight != 100 {
		t.Fatalf("second stage = %+v", stages[1])
	}
	if got := formatRoutingStages(stages); got != "openai-direct:70,openai-azure:30@2 | openrouter:100@1" {
		t.Fatalf("formatRoutingStages = %q", got)
	}
	if _, err := parseRoutingStages("openai-direct:not-a-number"); err == nil {
		t.Fatalf("expected invalid weight error")
	}
}

func TestStoredModelIDMigrationRules(t *testing.T) {
	offerings := []ModelIDMigrationOffering{
		{CanonicalModelID: "openai/gpt-4.1-2025-04-14", DeploymentID: "openai-direct", NativeModelID: "gpt-4.1-2025-04-14"},
		{CanonicalModelID: "openai/gpt-4.1-2025-04-14", DeploymentID: "openai-azure", NativeModelID: "my-gpt-4-1-prod"},
		{CanonicalModelID: "anthropic/claude-sonnet-4-20250514", DeploymentID: "anthropic-direct", NativeModelID: "claude-sonnet-4-20250514"},
		{CanonicalModelID: "openrouter/anthropic/claude-sonnet-4-20250514", DeploymentID: "openrouter", NativeModelID: "claude-sonnet-4-20250514"},
	}

	canonical := migrateStoredModelIDToCanonical(migrateStoredModelIDToCanonicalOptions{
		savedModelID: "openai/gpt-4.1-2025-04-14",
		offerings:    offerings,
		smartDefault: "fallback/model",
	})
	if canonical.Status != ModelIDMigrationCanonicalMatch || canonical.CanonicalModelID != "openai/gpt-4.1-2025-04-14" {
		t.Fatalf("canonical match = %+v", canonical)
	}

	uniqueNative := migrateStoredModelIDToCanonical(migrateStoredModelIDToCanonicalOptions{
		savedModelID: "my-gpt-4-1-prod",
		offerings:    offerings,
		smartDefault: "fallback/model",
	})
	if uniqueNative.Status != ModelIDMigrationUniqueNative || uniqueNative.CanonicalModelID != "openai/gpt-4.1-2025-04-14" {
		t.Fatalf("unique native match = %+v", uniqueNative)
	}

	ambiguous := migrateStoredModelIDToCanonical(migrateStoredModelIDToCanonicalOptions{
		savedModelID: "claude-sonnet-4-20250514",
		offerings:    offerings,
		smartDefault: "fallback/model",
	})
	if ambiguous.Status != ModelIDMigrationAmbiguousNative || ambiguous.CanonicalModelID != "fallback/model" || ambiguous.Diagnostic == "" {
		t.Fatalf("ambiguous native match = %+v", ambiguous)
	}

	fallback := migrateStoredModelIDToCanonical(migrateStoredModelIDToCanonicalOptions{
		savedModelID: "missing-model",
		offerings:    offerings,
		smartDefault: "fallback/model",
	})
	if fallback.Status != ModelIDMigrationFallback || fallback.CanonicalModelID != "fallback/model" || fallback.Diagnostic == "" {
		t.Fatalf("fallback = %+v", fallback)
	}
}

func containsJSONKey(data []byte, key string) bool {
	var values map[string]any
	if err := json.Unmarshal(data, &values); err != nil {
		return false
	}
	_, ok := values[key]
	return ok
}

func diagnosticPathCodes(diagnostics []RoutingDiagnostic) []string {
	values := make([]string, len(diagnostics))
	for i, diagnostic := range diagnostics {
		values[i] = diagnostic.Path + ":" + diagnostic.Code
	}
	return values
}
