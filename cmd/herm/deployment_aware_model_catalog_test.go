package main

import (
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"langdag.com/langdag"
	"langdag.com/langdag/types"
)

func catalogWithRouteDependentPricing() *langdag.ModelCatalog {
	catalog := langdag.ReferenceCatalogV1()
	generatedAt := time.Date(2026, 5, 15, 0, 0, 0, 0, time.UTC)
	catalog.GeneratedAt = generatedAt
	catalog.StaleAfter = generatedAt.Add(30 * 24 * time.Hour)
	catalog.Models = map[string]*langdag.ModelV1{
		"openai/gpt-route-priced": {
			ID:            "openai/gpt-route-priced",
			ProviderID:    "openai",
			Name:          "GPT Route Priced",
			ContextWindow: 128000,
		},
	}
	catalog.Offerings = []langdag.ModelOfferingV1{
		{
			ID:               "openai-direct:gpt-route-priced",
			CanonicalModelID: "openai/gpt-route-priced",
			DeploymentID:     "openai-direct",
			NativeModelID:    "gpt-route-priced",
			Pricing: langdag.PricingV1{
				Status:   langdag.PricingKnown,
				Currency: "USD",
				RatesPer1M: map[string]float64{
					"input_tokens":  2,
					"output_tokens": 8,
				},
			},
		},
		{
			ID:               "openrouter:openai/gpt-route-priced",
			CanonicalModelID: "openai/gpt-route-priced",
			DeploymentID:     "openrouter",
			NativeModelID:    "openai/gpt-route-priced",
			Pricing: langdag.PricingV1{
				Status:   langdag.PricingKnown,
				Currency: "USD",
				RatesPer1M: map[string]float64{
					"input_tokens":  3,
					"output_tokens": 15,
				},
			},
		},
	}
	catalog.OfferingTemplates = nil
	return catalog
}

func TestCatalogCanonicalCatalogRowsAndRoutePriceRange(t *testing.T) {
	models := modelsFromCatalog(catalogWithRouteDependentPricing())
	model := findModelByID(findModelByIDOptions{models: models, id: "openai/gpt-route-priced"})
	if model == nil {
		t.Fatal("canonical model row not found")
	}
	if model.ID != "openai/gpt-route-priced" || model.Provider != "openai" {
		t.Fatalf("model identity = %+v", *model)
	}
	if len(model.Deployments) != 2 {
		t.Fatalf("Deployments len = %d, want 2", len(model.Deployments))
	}
	if !model.RouteDependentPricing || model.PriceLabel != "$2-$3/$8-$15/M" {
		t.Fatalf("price summary = routeDependent:%v label:%q", model.RouteDependentPricing, model.PriceLabel)
	}
	if findModelByID(findModelByIDOptions{models: models, id: "gpt-route-priced"}) == nil {
		t.Fatal("native model ID should resolve to the canonical row for old-node fallback")
	}
	_, lines := formatModelMenuLines(formatModelMenuLinesOptions{models: []ModelDef{*model}, activeID: model.ID})
	if len(lines) != 1 || !strings.Contains(lines[0], "gpt-route-priced") || !strings.Contains(lines[0], "$2-$3/$8-$15/M") {
		t.Fatalf("picker line does not show canonical row and route range: %q", lines)
	}
}

func TestCatalogAvailabilityUsesOpenRouterAndAzureDeployments(t *testing.T) {
	openRouterOnly := ModelDef{
		Provider:      "z-ai",
		OwnerProvider: "z-ai",
		ID:            "z-ai/new-openrouter-only:free",
		Deployments: []ModelDeploymentDef{{
			DeploymentID: "openrouter",
			PricingSnapshot: types.PricingSnapshot{
				Status:     types.CostStatusFree,
				Currency:   "USD",
				Source:     types.CostSourceCatalog,
				RatesPer1M: map[string]float64{"input_tokens": 0, "output_tokens": 0},
			},
		}},
	}
	azureMapped := ModelDef{
		Provider:      "openai",
		OwnerProvider: "openai",
		ID:            "openai/gpt-4.1-2025-04-14",
		Deployments: []ModelDeploymentDef{{
			DeploymentID:    "openai-azure",
			MappingRequired: true,
			PricingSnapshot: types.PricingSnapshot{
				Status:     types.CostStatusKnown,
				Currency:   "USD",
				Source:     types.CostSourceCatalog,
				RatesPer1M: map[string]float64{"input_tokens": 2, "output_tokens": 8},
			},
		}},
	}
	models := []ModelDef{openRouterOnly, azureMapped}

	openRouterCfg := Config{OpenRouterAPIKey: "sk-or"}
	if got := openRouterCfg.availableModels(models); len(got) != 1 || got[0].ID != openRouterOnly.ID {
		t.Fatalf("OpenRouter-only availability = %+v", got)
	}

	azureNoMapping := Config{Deployments: map[string]DeploymentConfig{
		"openai-azure": {APIKey: "az", Endpoint: "https://example.openai.azure.com", APIVersion: "2024-08-01-preview"},
	}}
	if got := azureNoMapping.availableModels(models); len(got) != 0 {
		t.Fatalf("Azure without model_mappings should not expose model: %+v", got)
	}

	azureWithMapping := azureNoMapping
	azureWithMapping.Deployments = map[string]DeploymentConfig{
		"openai-azure": {
			APIKey:     "az",
			Endpoint:   "https://example.openai.azure.com",
			APIVersion: "2024-08-01-preview",
			ModelMappings: map[string]string{
				"openai/gpt-4.1-2025-04-14": "my-gpt-4-1-prod",
			},
		},
	}
	if got := azureWithMapping.availableModels(models); len(got) != 1 || got[0].ID != azureMapped.ID {
		t.Fatalf("Azure with model_mappings availability = %+v", got)
	}
}

func TestDeploymentRoutingAvailabilityHonorsAuthoritativeRoutingWithoutHidingMixedRoutes(t *testing.T) {
	model := ModelDef{
		Provider:      ProviderOpenAI,
		OwnerProvider: ProviderOpenAI,
		ID:            "openai/gpt-4.1-2025-04-14",
		Deployments: []ModelDeploymentDef{
			{DeploymentID: "openai-direct"},
			{DeploymentID: "openrouter"},
		},
	}
	cfg := Config{
		Deployments: map[string]DeploymentConfig{
			"openai-direct": {APIKey: "sk-openai"},
			"openrouter":    {APIKey: "sk-or"},
		},
		Routing: &RoutingPolicy{
			Models: map[string][]RoutingStage{
				model.ID: {{
					Deployments: []DeploymentChoice{
						{DeploymentID: "openai-azure", Weight: 100},
						{DeploymentID: "openrouter", Weight: 100},
					},
				}},
			},
		},
	}

	available := cfg.availableModels([]ModelDef{model})
	if len(available) != 1 {
		t.Fatalf("mixed route should keep callable model visible: %+v", available)
	}
	if len(available[0].Deployments) != 1 || available[0].Deployments[0].DeploymentID != "openrouter" {
		t.Fatalf("available route deployments = %+v", available[0].Deployments)
	}
	if len(available[0].RouteDiagnostics) == 0 {
		t.Fatalf("expected diagnostic for unavailable openai-azure route")
	}

	cfg.Routing.Models[model.ID] = []RoutingStage{{Deployments: []DeploymentChoice{{DeploymentID: "openai-azure", Weight: 100}}}}
	if available := cfg.availableModels([]ModelDef{model}); len(available) != 0 {
		t.Fatalf("authoritative model override with no eligible deployments should hide model: %+v", available)
	}
}

func TestDeploymentRoutingRoutingValidationIndexCapturesAzureMappingAvailability(t *testing.T) {
	model := ModelDef{
		Provider:      ProviderOpenAI,
		OwnerProvider: ProviderOpenAI,
		ID:            "openai/gpt-4.1-2025-04-14",
		Deployments: []ModelDeploymentDef{{
			DeploymentID:    "openai-azure",
			MappingRequired: true,
		}},
	}
	cfg := Config{Deployments: map[string]DeploymentConfig{
		"openai-azure": {APIKey: "sk", Endpoint: "https://example.openai.azure.com", APIVersion: "2024-08-01-preview"},
	}}

	index := routingValidationIndexForConfigModels(configModelsOptions{cfg: cfg, models: []ModelDef{model}})
	if index.EligibleDeploymentsByModel[model.ID]["openai-azure"] {
		t.Fatalf("Azure deployment should not be eligible without model mapping")
	}
	if !index.MissingMappingsByModel[model.ID]["openai-azure"] {
		t.Fatalf("missing Azure mapping not recorded: %+v", index.MissingMappingsByModel)
	}

	cfg.Deployments["openai-azure"] = DeploymentConfig{
		APIKey:     "sk",
		Endpoint:   "https://example.openai.azure.com",
		APIVersion: "2024-08-01-preview",
		ModelMappings: map[string]string{
			model.ID: "my-gpt-4-1-prod",
		},
	}
	index = routingValidationIndexForConfigModels(configModelsOptions{cfg: cfg, models: []ModelDef{model}})
	if !index.EligibleDeploymentsByModel[model.ID]["openai-azure"] {
		t.Fatalf("Azure deployment should be eligible with model mapping: %+v", index.EligibleDeploymentsByModel)
	}
}

func TestCatalogEnvOnlyDeploymentConfiguresAvailability(t *testing.T) {
	t.Setenv("OPENAI_API_KEY", "sk-env")
	cfg := Config{}
	if !cfg.configuredProviders()[ProviderOpenAI] {
		t.Fatalf("OPENAI_API_KEY env should configure OpenAI provider: %+v", cfg.configuredProviders())
	}
	deployments := langdagDeploymentsFromConfig(cfg)
	if deployments["openai-direct"].APIKey != "sk-env" {
		t.Fatalf("env-only langdag deployments = %+v", deployments)
	}
	models := []ModelDef{{
		Provider:      "openai",
		OwnerProvider: "openai",
		ID:            "openai/gpt-env",
		Deployments: []ModelDeploymentDef{{
			DeploymentID: "openai-direct",
			PricingSnapshot: types.PricingSnapshot{
				Status:     types.CostStatusKnown,
				Currency:   "USD",
				Source:     types.CostSourceCatalog,
				RatesPer1M: map[string]float64{"input_tokens": 1, "output_tokens": 2},
			},
		}},
	}}
	if got := cfg.availableModels(models); len(got) != 1 || got[0].ID != "openai/gpt-env" {
		t.Fatalf("env-only availability = %+v", got)
	}
}

func TestCatalogConfiguredProviderUsesEligibleDeployment(t *testing.T) {
	model := ModelDef{
		Provider:      "openai",
		OwnerProvider: "openai",
		ID:            "openai/gpt-route",
		Deployments: []ModelDeploymentDef{
			{
				DeploymentID:    "openai-azure",
				MappingRequired: true,
				PricingSnapshot: types.PricingSnapshot{Status: types.CostStatusKnown, Currency: "USD", Source: types.CostSourceCatalog, RatesPer1M: map[string]float64{"input_tokens": 2, "output_tokens": 8}},
			},
			{
				DeploymentID:    "openrouter",
				PricingSnapshot: types.PricingSnapshot{Status: types.CostStatusKnown, Currency: "USD", Source: types.CostSourceCatalog, RatesPer1M: map[string]float64{"input_tokens": 3, "output_tokens": 15}},
			},
		},
	}
	cfg := Config{
		OpenRouterAPIKey: "sk-or",
		Deployments: map[string]DeploymentConfig{
			"openai-azure": {APIKey: "az", Endpoint: "https://example.openai.azure.com", APIVersion: "2024-08-01-preview"},
		},
	}
	if got := configuredProviderForModel(configuredProviderForModelOptions{cfg: cfg, model: model}); got != ProviderOpenRouter {
		t.Fatalf("configuredProviderForModel = %q, want openrouter for eligible route", got)
	}
}

func TestCatalogConfigRowsShowCanonicalOpenRouterSelection(t *testing.T) {
	model := ModelDef{
		Provider:      "z-ai",
		OwnerProvider: "z-ai",
		ID:            "z-ai/new-openrouter-only:free",
		Deployments: []ModelDeploymentDef{{
			DeploymentID: "openrouter",
			PricingSnapshot: types.PricingSnapshot{
				Status:     types.CostStatusFree,
				Currency:   "USD",
				Source:     types.CostSourceCatalog,
				RatesPer1M: map[string]float64{"input_tokens": 0, "output_tokens": 0},
			},
		}},
	}
	cfg := Config{OpenRouterAPIKey: "sk-or", ActiveModel: model.ID}
	app := &App{cfgDraft: cfg, models: []ModelDef{model}, cfgTab: cfgTabGlobal, width: 100}
	rows := strings.Join(app.buildConfigRows(), "\n")
	if !strings.Contains(rows, model.ID) {
		t.Fatalf("config rows should show canonical OpenRouter selection, got:\n%s", rows)
	}

	app.doOpenConfigModelPicker(doOpenConfigModelPickerOptions{
		models:       []ModelDef{model},
		getCurrentID: func() string { return model.ID },
		onSelect:     func(string) {},
	})
	if len(app.menuModels) != 1 || app.menuModels[0].ID != model.ID {
		t.Fatalf("OpenRouter picker should not add duplicate unavailable stub: %+v", app.menuModels)
	}

	missingID := "z-ai/missing-openrouter-model"
	app = &App{cfgDraft: Config{OpenRouterAPIKey: "sk-or", ActiveModel: missingID}, models: []ModelDef{model}, width: 100}
	app.doOpenConfigModelPicker(doOpenConfigModelPickerOptions{
		models:       []ModelDef{model},
		getCurrentID: func() string { return missingID },
		onSelect:     func(string) {},
	})
	stub := findModelByID(findModelByIDOptions{models: app.menuModels, id: missingID})
	if len(app.menuModels) != 2 || stub == nil || !strings.Contains(stub.Label, "unavailable") || stub.PriceLabel != "unknown" {
		t.Fatalf("OpenRouter picker should keep unavailable saved selection as a stub: %+v", app.menuModels)
	}
}

func TestCatalogServerToolsUseEligibleDeploymentsOnly(t *testing.T) {
	model := ModelDef{
		Provider:      "anthropic",
		OwnerProvider: "anthropic",
		ID:            "anthropic/claude-route",
		Deployments: []ModelDeploymentDef{
			{
				DeploymentID: "anthropic-direct",
				ServerTools:  []string{types.ServerToolWebSearch},
				PricingSnapshot: types.PricingSnapshot{
					Status:     types.CostStatusKnown,
					Currency:   "USD",
					Source:     types.CostSourceCatalog,
					RatesPer1M: map[string]float64{"input_tokens": 3, "output_tokens": 15},
				},
			},
			{
				DeploymentID: "openrouter",
				PricingSnapshot: types.PricingSnapshot{
					Status:     types.CostStatusKnown,
					Currency:   "USD",
					Source:     types.CostSourceCatalog,
					RatesPer1M: map[string]float64{"input_tokens": 4, "output_tokens": 16},
				},
			},
		},
		ServerTools: []string{types.ServerToolWebSearch},
	}
	cfg := Config{OpenRouterAPIKey: "sk-or"}
	available := cfg.availableModels([]ModelDef{model})
	if len(available) != 1 {
		t.Fatalf("available models = %+v", available)
	}
	if supportsServerTools(supportsServerToolsOptions{models: available, modelID: model.ID}) {
		t.Fatal("server tools should not be enabled when only the non-tool OpenRouter deployment is eligible")
	}
}

func TestCatalogOpenRouterDynamicMergeAvoidsDuplicateCanonicalRows(t *testing.T) {
	base := modelsFromCatalog(catalogWithRouteDependentPricing())
	dynamic := []ModelDef{{
		Provider:      ProviderOpenRouter,
		OwnerProvider: "openai",
		ID:            "openai/gpt-route-priced",
		CanonicalID:   "openai/gpt-route-priced",
		Deployments: []ModelDeploymentDef{{
			DeploymentID:  "openrouter",
			OfferingID:    "openrouter:openai/gpt-route-priced",
			NativeModelID: "openai/gpt-route-priced",
			PricingSnapshot: types.PricingSnapshot{
				Status:     types.CostStatusKnown,
				Currency:   "USD",
				Source:     types.CostSourceCatalog,
				RatesPer1M: map[string]float64{"input_tokens": 3, "output_tokens": 15},
			},
		}},
		NativeModelIDs: []string{"openai/gpt-route-priced"},
	}}
	merged := mergeDynamicModels(mergeDynamicModelsOptions{base: base, dynamic: dynamic})
	var count int
	for _, model := range merged {
		if model.ID == "openai/gpt-route-priced" {
			count++
		}
	}
	if count != 1 {
		t.Fatalf("canonical OpenRouter merge produced %d rows, want 1: %+v", count, merged)
	}
	result := computeCostResult(computeCostOptions{models: merged, modelID: "openai/gpt-route-priced", usage: types.Usage{InputTokens: 1000, OutputTokens: 500}})
	if result.Status != types.CostStatusUnknown || len(result.MissingDimensions) == 0 || !strings.HasPrefix(result.MissingDimensions[0], "route_dependent_pricing:") {
		t.Fatalf("route-dependent canonical fallback should be explicit unknown, got %+v", result)
	}
}

func TestCatalogLoadedConfigMigratesOldModelIDs(t *testing.T) {
	dir := t.TempDir()
	cfgDir := filepath.Join(dir, configDir)
	if err := os.MkdirAll(cfgDir, 0o755); err != nil {
		t.Fatalf("mkdir config dir: %v", err)
	}
	raw := []byte(`{"active_model":"gpt-4.1-2025-04-14","exploration_model":"claude-haiku-4-5","openai_api_key":"sk"}`)
	if err := os.WriteFile(filepath.Join(cfgDir, configFile), raw, 0o644); err != nil {
		t.Fatalf("write config: %v", err)
	}
	cfg, err := loadConfigFrom(dir)
	if err != nil {
		t.Fatalf("loadConfigFrom: %v", err)
	}
	if cfg.ActiveModel != "openai/gpt-4.1-2025-04-14" || cfg.ExplorationModel != "anthropic/claude-haiku-4-5" {
		t.Fatalf("models did not migrate to canonical IDs: %+v", cfg)
	}
}

func TestCatalogLoadedConfigPreservesUnknownOllamaAsCanonical(t *testing.T) {
	dir := t.TempDir()
	cfgDir := filepath.Join(dir, configDir)
	if err := os.MkdirAll(cfgDir, 0o755); err != nil {
		t.Fatalf("mkdir config dir: %v", err)
	}
	raw := []byte(`{"active_model":"llama3.1:8b","exploration_model":"qwen2.5-coder:7b","ollama_base_url":"http://localhost:11434"}`)
	if err := os.WriteFile(filepath.Join(cfgDir, configFile), raw, 0o644); err != nil {
		t.Fatalf("write config: %v", err)
	}
	cfg, err := loadConfigFrom(dir)
	if err != nil {
		t.Fatalf("loadConfigFrom: %v", err)
	}
	if cfg.ActiveModel != "ollama/llama3.1:8b" || cfg.ExplorationModel != "ollama/qwen2.5-coder:7b" {
		t.Fatalf("Ollama models should migrate to canonical Ollama IDs, got %+v", cfg)
	}
}

func TestCatalogLangdagDeploymentsAndRoutingPolicy(t *testing.T) {
	cfg := Config{
		OpenAIAPIKey:     "sk-openai",
		OpenRouterAPIKey: "sk-or",
		Routing: &RoutingPolicy{
			Default: []RoutingStage{{
				Deployments: []DeploymentChoice{{DeploymentID: "openrouter", Weight: 100}},
				Retries:     1,
			}},
			Providers: map[string][]RoutingStage{
				"openai": {{
					Deployments: []DeploymentChoice{{DeploymentID: "openai-direct", Weight: 100}},
					Retries:     2,
				}},
			},
		},
	}
	deployments := langdagDeploymentsFromConfig(cfg)
	if deployments["openai-direct"].APIKey != "sk-openai" || deployments["openrouter"].APIKey != "sk-or" {
		t.Fatalf("langdag deployments = %+v", deployments)
	}
	policy := langdagRoutingPolicyFromConfig(cfg.Routing)
	if policy == nil || len(policy.Default) != 1 || len(policy.Providers["openai"]) != 1 {
		t.Fatalf("routing policy conversion = %+v", policy)
	}
	if policy.Providers["openai"][0].Deployments[0].DeploymentID != "openai-direct" || policy.Providers["openai"][0].Retries != 2 {
		t.Fatalf("provider route conversion = %+v", policy.Providers["openai"])
	}
}

func TestCatalogExactProviderCostAndOldNodeFallback(t *testing.T) {
	metadata := types.AssistantNodeMetadata{
		NormalizedUsage: &types.NormalizedUsage{InputTokens: 1000, OutputTokens: 500},
		PricingSnapshot: &types.PricingSnapshot{
			Status:     types.CostStatusKnown,
			Currency:   "USD",
			Source:     types.CostSourceCatalog,
			RatesPer1M: map[string]float64{"input_tokens": 2, "output_tokens": 8},
		},
		ProviderCost: &types.ProviderCost{Total: 0.42, Currency: "USD", Source: types.CostSourceProviderResponse},
	}
	rawMetadata, err := json.Marshal(metadata)
	if err != nil {
		t.Fatalf("Marshal metadata: %v", err)
	}
	app := &App{models: []ModelDef{{
		Provider:        "openai",
		OwnerProvider:   "openai",
		ID:              "openai/gpt-4.1-2025-04-14",
		NativeModelIDs:  []string{"gpt-4.1-2025-04-14"},
		PromptPrice:     2,
		CompletionPrice: 8,
		PricingStatus:   types.CostStatusKnown,
	}}}

	exact := app.nodeCostResult(&types.Node{Model: "openai/gpt-4.1-2025-04-14", Metadata: rawMetadata})
	if exact.Source != types.CostSourceProviderResponse || math.Abs(exact.Total-0.42) > 1e-12 {
		t.Fatalf("provider exact cost not preferred: %+v", exact)
	}

	old := app.nodeCostResult(&types.Node{Model: "gpt-4.1-2025-04-14", TokensIn: 1000, TokensOut: 500})
	want := (1000*2 + 500*8) / 1_000_000.0
	if old.Status != types.CostStatusKnown || math.Abs(old.Total-want) > 1e-12 {
		t.Fatalf("old-node native fallback = %+v, want %f", old, want)
	}
}

func TestCatalogStructuredUnknownCostIsAuthoritative(t *testing.T) {
	metadata := types.AssistantNodeMetadata{
		NormalizedUsage: &types.NormalizedUsage{InputTokens: 1000, OutputTokens: 500},
		PricingSnapshot: &types.PricingSnapshot{
			Status:            types.CostStatusUnknown,
			Currency:          "USD",
			Source:            types.CostSourceCatalog,
			MissingDimensions: []string{"route_dependent_pricing:openai/gpt-route"},
		},
	}
	rawMetadata, err := json.Marshal(metadata)
	if err != nil {
		t.Fatalf("Marshal metadata: %v", err)
	}
	app := &App{models: []ModelDef{{
		Provider:        "openai",
		OwnerProvider:   "openai",
		ID:              "openai/gpt-route",
		PromptPrice:     2,
		CompletionPrice: 8,
		PricingStatus:   types.CostStatusKnown,
	}}}
	cost := app.nodeCostResult(&types.Node{Model: "openai/gpt-route", Metadata: rawMetadata, TokensIn: 1000, TokensOut: 500})
	if cost.Status != types.CostStatusUnknown || len(cost.MissingDimensions) != 1 {
		t.Fatalf("structured unknown pricing should not fall back to current catalog estimate: %+v", cost)
	}
	fallback := types.CostResult{Status: types.CostStatusKnown, Total: 0.01}
	preferred := preferStructuredCost(structuredCostPreference{metadataCost: cost, fallbackCost: fallback})
	if preferred.Status != types.CostStatusUnknown {
		t.Fatalf("preferStructuredCost should keep authoritative structured unknown, got %+v", preferred)
	}
}

func TestCatalogAggregateCostKeepsUnknownStatus(t *testing.T) {
	app := &App{models: []ModelDef{{
		Provider:              "openai",
		OwnerProvider:         "openai",
		ID:                    "openai/gpt-route",
		RouteDependentPricing: true,
		PricingStatus:         types.CostStatusKnown,
		NativeModelIDs:        []string{"gpt-route"},
	}}}
	nodes := []*types.Node{
		{NodeType: types.NodeTypeAssistant, Model: "gpt-route", TokensIn: 1000, TokensOut: 500},
		{NodeType: types.NodeTypeAssistant, Model: "missing-model", TokensIn: 1000, TokensOut: 500},
	}
	cost, ok := app.aggregateDisplayedNodeCosts(nodes)
	if !ok {
		t.Fatal("expected aggregate cost")
	}
	if cost.Status != types.CostStatusUnknown || formatCostResult(cost) != "cost unknown" {
		t.Fatalf("aggregate cost should preserve unknown status, got %+v displayed as %q", cost, formatCostResult(cost))
	}
	rendered := app.renderTree(nodes)
	if !strings.Contains(rendered, "Total: cost unknown") {
		t.Fatalf("rendered tree should show unknown aggregate cost, got:\n%s", rendered)
	}
}
