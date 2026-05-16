package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"langdag.com/langdag"
	"langdag.com/langdag/types"
)

func phase8HermCatalog(canonicalID, directNativeID, openRouterNativeID string) *langdag.ModelCatalog {
	catalog := langdag.ReferenceCatalogV1()
	generatedAt := time.Date(2026, 5, 20, 0, 0, 0, 0, time.UTC)
	catalog.GeneratedAt = generatedAt
	catalog.StaleAfter = generatedAt.Add(30 * 24 * time.Hour)
	addPhase8HermCatalogModel(catalog, generatedAt, canonicalID, directNativeID, openRouterNativeID)
	return catalog
}

func addPhase8HermCatalogModel(catalog *langdag.ModelCatalog, generatedAt time.Time, canonicalID, directNativeID, openRouterNativeID string) {
	catalog.Models[canonicalID] = &langdag.ModelV1{
		ID:            canonicalID,
		ProviderID:    "openai",
		Name:          "GPT Phase 8 Herm",
		ContextWindow: 128000,
	}
	catalog.Offerings = append(catalog.Offerings,
		langdag.ModelOfferingV1{
			ID:               "openai-direct:" + directNativeID,
			CanonicalModelID: canonicalID,
			DeploymentID:     "openai-direct",
			NativeModelID:    directNativeID,
			Pricing: langdag.PricingV1{
				Status:      langdag.PricingKnown,
				Currency:    "USD",
				EffectiveAt: generatedAt,
				RatesPer1M:  map[string]float64{"input_tokens": 2, "output_tokens": 8},
			},
		},
		langdag.ModelOfferingV1{
			ID:               "openrouter:" + openRouterNativeID,
			CanonicalModelID: canonicalID,
			DeploymentID:     "openrouter",
			NativeModelID:    openRouterNativeID,
			Pricing: langdag.PricingV1{
				Status:      langdag.PricingKnown,
				Currency:    "USD",
				EffectiveAt: generatedAt,
				RatesPer1M:  map[string]float64{"input_tokens": 2, "output_tokens": 8},
			},
		},
	)
}

func writePhase8HermCatalogCache(t *testing.T, path string, catalog *langdag.ModelCatalog) {
	t.Helper()
	if err := langdag.ValidateCatalogV1(catalog); err != nil {
		t.Fatalf("test catalog is invalid: %v", err)
	}
	data, err := json.MarshalIndent(catalog, "", "  ")
	if err != nil {
		t.Fatalf("marshal catalog: %v", err)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("mkdir cache dir: %v", err)
	}
	if err := os.WriteFile(path, append(data, '\n'), 0o644); err != nil {
		t.Fatalf("write cache: %v", err)
	}
}

func servePhase8HermCatalog(t *testing.T, catalog *langdag.ModelCatalog) *httptest.Server {
	t.Helper()
	if err := langdag.ValidateCatalogV1(catalog); err != nil {
		t.Fatalf("test catalog is invalid: %v", err)
	}
	data, err := json.Marshal(catalog)
	if err != nil {
		t.Fatalf("marshal catalog: %v", err)
	}
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(data)
	}))
}

func clearPhase8CredentialEnv(t *testing.T) {
	t.Helper()
	for _, name := range []string{
		"ANTHROPIC_API_KEY",
		"OPENAI_API_KEY",
		"OPENAI_BASE_URL",
		"GEMINI_API_KEY",
		"XAI_API_KEY",
		"XAI_BASE_URL",
		"OPENROUTER_API_KEY",
		"OPENROUTER_BASE_URL",
		"OLLAMA_BASE_URL",
		"AZURE_OPENAI_API_KEY",
		"AZURE_OPENAI_ENDPOINT",
		"AZURE_OPENAI_API_VERSION",
		"VERTEX_PROJECT_ID",
		"VERTEX_REGION",
		"AWS_REGION",
	} {
		t.Setenv(name, "")
	}
}

func TestPhase8HermCatalogStartupSourcesIntegration(t *testing.T) {
	clearPhase8CredentialEnv(t)

	embedded, err := langdag.LoadModelCatalogWithOptions(langdag.CatalogLoadOptions{
		CachePath: filepath.Join(t.TempDir(), "missing-catalog.json"),
	})
	if err != nil {
		t.Fatalf("Load embedded fallback: %v", err)
	}
	if embedded.Source != langdag.CatalogSourceEmbedded {
		t.Fatalf("embedded source = %q", embedded.Source)
	}
	app := &App{resultCh: make(chan any, 8)}
	app.handleResult(catalogMsg{catalog: embedded.Catalog, source: embedded.Source, diagnostics: embedded.Diagnostics})
	if app.modelCatalog == nil || len(app.models) == 0 {
		t.Fatalf("embedded catalog did not populate app models")
	}

	cachePath := filepath.Join(t.TempDir(), "model_catalog.json")
	cachedCatalog := phase8HermCatalog("openai/gpt-phase8-cached", "gpt-phase8-cached", "openai/gpt-phase8-cached")
	writePhase8HermCatalogCache(t, cachePath, cachedCatalog)
	cached, err := langdag.LoadModelCatalogWithOptions(langdag.CatalogLoadOptions{CachePath: cachePath})
	if err != nil {
		t.Fatalf("Load cached catalog: %v", err)
	}
	if cached.Source != langdag.CatalogSourceCache {
		t.Fatalf("cached source = %q", cached.Source)
	}
	app.handleResult(catalogMsg{catalog: cached.Catalog, source: cached.Source, diagnostics: cached.Diagnostics})
	if findModelByID(findModelByIDOptions{models: app.models, id: "openai/gpt-phase8-cached"}) == nil {
		t.Fatalf("cached catalog model not available after startup handling")
	}

	remoteCatalog := phase8HermCatalog("openai/gpt-phase8-remote", "gpt-phase8-remote", "openai/gpt-phase8-remote")
	server := servePhase8HermCatalog(t, remoteCatalog)
	defer server.Close()
	refreshed, err := langdag.RefreshModelCatalogCache(context.Background(), langdag.CatalogRefreshOptions{
		CachePath: cachePath,
		Endpoint:  server.URL,
		Timeout:   time.Second,
		Now:       func() time.Time { return remoteCatalog.GeneratedAt.Add(time.Hour) },
	})
	if err != nil {
		t.Fatalf("RefreshModelCatalogCache: %v", err)
	}
	app.handleResult(catalogMsg{catalog: refreshed.Catalog, source: refreshed.Source, diagnostics: refreshed.Diagnostics})
	if findModelByID(findModelByIDOptions{models: app.models, id: "openai/gpt-phase8-remote"}) == nil {
		t.Fatalf("refreshed remote catalog model not available after startup handling")
	}
	if findModelByID(findModelByIDOptions{models: app.models, id: "openai/gpt-phase8-cached"}) != nil {
		t.Fatalf("stale cached model remained after refreshed catalog replacement")
	}
}

func TestPhase8HermConfigRoutingHistoryAndSmartDefaultsIntegration(t *testing.T) {
	clearPhase8CredentialEnv(t)

	const canonicalID = "openai/gpt-phase8-herm"
	const nativeID = "gpt-phase8-herm"
	const explorationID = "openai/gpt-phase8-herm-mini"
	catalog := phase8HermCatalog(canonicalID, nativeID, "openai/gpt-phase8-herm")
	addPhase8HermCatalogModel(catalog, catalog.GeneratedAt, explorationID, "gpt-phase8-herm-mini", "openai/gpt-phase8-herm-mini")
	models := modelsFromCatalog(catalog)
	if findModelByID(findModelByIDOptions{models: models, id: canonicalID}) == nil {
		t.Fatalf("phase8 model not present in catalog-derived rows")
	}

	oldDefault := defaultActiveModels[ProviderOpenAI]
	oldExplorationDefault := defaultExplorationModels[ProviderOpenAI]
	defaultActiveModels[ProviderOpenAI] = canonicalID
	defaultExplorationModels[ProviderOpenAI] = explorationID
	t.Cleanup(func() {
		defaultActiveModels[ProviderOpenAI] = oldDefault
		defaultExplorationModels[ProviderOpenAI] = oldExplorationDefault
	})

	defaultCfg := normalizeLoadedConfig(Config{
		OpenAIAPIKey:     "sk-openai",
		OpenRouterAPIKey: "sk-or",
	})
	if active := defaultCfg.resolveActiveModel(models); active != canonicalID {
		t.Fatalf("smart active default = %q, want canonical phase8 model", active)
	}
	if exploration := defaultCfg.resolveExplorationModel(models); exploration != explorationID {
		t.Fatalf("smart exploration default = %q, want canonical phase8 exploration model", exploration)
	}
	defaultAvailable := defaultCfg.availableModels(models)
	defaultModel := findModelByID(findModelByIDOptions{models: defaultAvailable, id: canonicalID})
	if defaultModel == nil || len(defaultModel.Deployments) < 2 {
		t.Fatalf("smart-default scenario should keep multiple serving deployments visible: %+v", defaultModel)
	}

	routedCfg := normalizeLoadedConfig(Config{
		OpenAIAPIKey:     "sk-openai",
		OpenRouterAPIKey: "sk-or",
		Routing: &RoutingPolicy{
			Providers: map[string][]RoutingStage{
				"openai": {{
					Deployments: []DeploymentChoice{{DeploymentID: "openrouter", Weight: 100}},
				}},
			},
			Models: map[string][]RoutingStage{
				canonicalID: {{
					Deployments: []DeploymentChoice{{DeploymentID: "openrouter", Weight: 100}},
				}},
			},
		},
	})
	available := routedCfg.availableModels(models)
	routed := findModelByID(findModelByIDOptions{models: available, id: canonicalID})
	if routed == nil || len(routed.Deployments) != 1 || routed.Deployments[0].DeploymentID != "openrouter" {
		t.Fatalf("route-specific available model = %+v", routed)
	}

	cfgWithoutOpenRouter := routedCfg
	cfgWithoutOpenRouter.OpenRouterAPIKey = ""
	cfgWithoutOpenRouter.Deployments = map[string]DeploymentConfig{
		"openai-direct": {APIKey: "sk-openai"},
	}
	if available := cfgWithoutOpenRouter.availableModels(models); findModelByID(findModelByIDOptions{models: available, id: canonicalID}) != nil {
		t.Fatalf("model route should be unavailable when its only routed deployment loses credentials")
	}

	migrated := normalizeLoadedConfig(Config{OpenAIAPIKey: "sk-openai", ActiveModel: "gpt-4.1-2025-04-14"})
	if migrated.ActiveModel != defaultCanonicalActiveModel {
		t.Fatalf("old native active model migrated to %q, want %q", migrated.ActiveModel, defaultCanonicalActiveModel)
	}

	client, err := langdag.New(langdag.Config{
		StoragePath: filepath.Join(t.TempDir(), "old-conversation.db"),
		Provider:    "ollama",
		OllamaConfig: &langdag.OllamaConfig{
			BaseURL: "http://127.0.0.1:11434",
		},
	})
	if err != nil {
		t.Fatalf("langdag.New old conversation DB: %v", err)
	}
	defer client.Close()
	now := time.Date(2026, 5, 20, 1, 0, 0, 0, time.UTC)
	if err := client.Storage().CreateNode(context.Background(), &types.Node{
		ID:        "old-root",
		RootID:    "old-root",
		Sequence:  0,
		NodeType:  types.NodeTypeUser,
		Content:   "old prompt",
		Status:    "completed",
		CreatedAt: now,
	}); err != nil {
		t.Fatalf("create old root node: %v", err)
	}
	if err := client.Storage().CreateNode(context.Background(), &types.Node{
		ID:        "old-assistant",
		ParentID:  "old-root",
		RootID:    "old-root",
		Sequence:  1,
		NodeType:  types.NodeTypeAssistant,
		Content:   "old answer",
		Model:     nativeID,
		TokensIn:  1000,
		TokensOut: 500,
		Status:    "completed",
		CreatedAt: now.Add(time.Second),
	}); err != nil {
		t.Fatalf("create old assistant node: %v", err)
	}
	nodes, err := client.GetSubtree(context.Background(), "old-root")
	if err != nil {
		t.Fatalf("GetSubtree old conversation DB: %v", err)
	}
	if len(nodes) != 2 {
		t.Fatalf("old conversation subtree len = %d, want 2", len(nodes))
	}
	app := &App{models: models}
	oldNodeCost := app.nodeCostResult(nodes[1])
	if oldNodeCost.Status != types.CostStatusKnown || oldNodeCost.Total == 0 {
		t.Fatalf("old conversation node cost fallback = %+v", oldNodeCost)
	}
	if rendered := app.renderTree(nodes); !strings.Contains(rendered, "Total:") {
		t.Fatalf("old conversation DB render did not include historical cost total:\n%s", rendered)
	}
}
