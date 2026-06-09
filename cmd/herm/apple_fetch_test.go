package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"langdag.com/langdag"
	"langdag.com/langdag/types"
)

func TestFetchAppleModelsRequiresDarwin(t *testing.T) {
	restore := runtimeGOOS
	runtimeGOOS = func() string { return "linux" }
	defer func() { runtimeGOOS = restore }()

	if models := fetchAppleModelsFrom(fetchAppleModelsOptions{baseURL: "http://127.0.0.1:1"}); models != nil {
		t.Fatalf("models = %+v, want nil on non-darwin", models)
	}
}

func TestFetchAppleModelsFiltersHealthyExpectedModels(t *testing.T) {
	restore := runtimeGOOS
	runtimeGOOS = func() string { return "darwin" }
	defer func() { runtimeGOOS = restore }()

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/health" {
			t.Fatalf("path = %q, want /health", r.URL.Path)
		}
		_, _ = w.Write([]byte(`{"status":"fm serve is running","models":[{"name":"system","available":true},{"name":"pcc","available":false},{"name":"other","available":true}]}`))
	}))
	defer srv.Close()

	models := fetchAppleModelsFrom(fetchAppleModelsOptions{baseURL: srv.URL})
	if len(models) != 1 {
		t.Fatalf("models = %+v, want one", models)
	}
	model := models[0]
	if model.Provider != ProviderApple || model.ID != "apple/system" {
		t.Fatalf("model identity = %+v", model)
	}
	if len(model.Deployments) != 1 || model.Deployments[0].DeploymentID != "apple-local" || model.Deployments[0].NativeModelID != "system" {
		t.Fatalf("deployment = %+v", model.Deployments)
	}
	if model.PriceLabel != "free" {
		t.Fatalf("PriceLabel = %q, want free", model.PriceLabel)
	}
}

func TestFetchAppleModelsRequiresHealthyStatus(t *testing.T) {
	restore := runtimeGOOS
	runtimeGOOS = func() string { return "darwin" }
	defer func() { runtimeGOOS = restore }()

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"status":"stopped","models":[{"name":"system","available":true}]}`))
	}))
	defer srv.Close()

	if models := fetchAppleModelsFrom(fetchAppleModelsOptions{baseURL: srv.URL}); models != nil {
		t.Fatalf("models = %+v, want nil when health status is not running", models)
	}
}

func TestFetchAppleModelsSupportsLegacyIDField(t *testing.T) {
	restore := runtimeGOOS
	runtimeGOOS = func() string { return "darwin" }
	defer func() { runtimeGOOS = restore }()

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"status":"fm serve is running","models":[{"id":"pcc","available":true}]}`))
	}))
	defer srv.Close()

	models := fetchAppleModelsFrom(fetchAppleModelsOptions{baseURL: srv.URL})
	if len(models) != 1 || models[0].ID != "apple/pcc" || models[0].Deployments[0].NativeModelID != "pcc" {
		t.Fatalf("models = %+v, want pcc from legacy id field", models)
	}
}

func TestAppleBaseURLDefaultEnvAndConfig(t *testing.T) {
	t.Setenv("APPLE_FM_BASE_URL", "")
	if got := (Config{}).appleFMBaseURL(); got != appleFMDefaultBaseURL {
		t.Fatalf("default appleFMBaseURL = %q", got)
	}

	t.Setenv("APPLE_FM_BASE_URL", "http://127.0.0.1:2999")
	if got := (Config{}).appleFMBaseURL(); got != "http://127.0.0.1:2999" {
		t.Fatalf("env appleFMBaseURL = %q", got)
	}

	cfg := Config{Deployments: map[string]DeploymentConfig{"apple-local": {BaseURL: "http://localhost:3001"}}}
	if got := cfg.appleFMBaseURL(); got != "http://localhost:3001" {
		t.Fatalf("config appleFMBaseURL = %q", got)
	}
	if !cfg.configuredDeploymentIDs()["apple-local"] {
		t.Fatal("explicit apple-local base_url should configure deployment")
	}
}

func TestAppleDynamicModelAvailabilityWithoutSavedConfig(t *testing.T) {
	model := appleRuntimeModel("system")
	available := (Config{}).availableModels([]ModelDef{model})
	if len(available) != 1 || available[0].ID != "apple/system" {
		t.Fatalf("available = %+v, want dynamic Apple model", available)
	}
}

func TestAppleCatalogModelNotAvailableWithoutSavedConfigOrHealth(t *testing.T) {
	model := appleRuntimeModel("system")
	model.RuntimeDiscovered = false

	available := (Config{}).availableModels([]ModelDef{model})
	if len(available) != 0 {
		t.Fatalf("available = %+v, want no static Apple model without config or health", available)
	}
}

func TestDefaultLangdagProviderDoesNotShortcutSavedAppleModel(t *testing.T) {
	cfg := Config{ActiveModel: "apple/system", ExplorationModel: "apple/pcc"}
	if got := cfg.defaultLangdagProvider(); got != "" {
		t.Fatalf("defaultLangdagProvider = %q, want empty until Apple is configured through availability", got)
	}
}

func TestDefaultURLAppleVisibleInitializesClientAndProviderSelection(t *testing.T) {
	tmp := t.TempDir()
	t.Setenv("HOME", tmp)

	models := []ModelDef{appleRuntimeModel("system")}
	cfg := Config{}
	if got := cfg.defaultLangdagProviderForModels(models); got != ProviderApple {
		t.Fatalf("defaultLangdagProviderForModels = %q, want apple", got)
	}
	client, err := newLangdagClientForModelsWithCatalog(newLangdagClientForModelsWithCatalogOptions{cfg: cfg, models: models})
	if err != nil {
		t.Fatalf("newLangdagClientForModelsWithCatalog error: %v", err)
	}
	if client == nil {
		t.Fatal("client = nil, want Apple client from default URL")
	}
	_ = client.Close()
}

func TestRuntimeAppleModelsAddDeploymentWithConfiguredProvider(t *testing.T) {
	clearDeploymentCredentialEnv(t)
	tmp := t.TempDir()
	t.Setenv("HOME", tmp)
	appleSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/health" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"status":"fm serve is running","models":[{"name":"system","available":true}]}`))
	}))
	defer appleSrv.Close()
	openRouterSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/models" {
			http.Error(w, "unexpected OpenRouter request", http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"data":[]}`))
	}))
	defer openRouterSrv.Close()
	t.Setenv("APPLE_FM_BASE_URL", appleSrv.URL)

	cfg := Config{Deployments: map[string]DeploymentConfig{"openrouter": {APIKey: "sk-openrouter", BaseURL: openRouterSrv.URL}}}
	models := []ModelDef{appleRuntimeModel("system")}
	if got := cfg.defaultLangdagProviderForModels(models); got != ProviderOpenRouter {
		t.Fatalf("defaultLangdagProviderForModels = %q, want openrouter", got)
	}
	client, err := newLangdagClientForModelsWithCatalog(newLangdagClientForModelsWithCatalogOptions{cfg: cfg, models: models})
	if err != nil {
		t.Fatalf("newLangdagClientForModelsWithCatalog error: %v", err)
	}
	if client == nil {
		t.Fatal("client = nil, want configured provider client")
	}
	defer client.Close()

	if !providerHasModel(client.Provider().Models(), "apple/system") {
		t.Fatalf("provider models do not include apple/system; apple-local was not routeable")
	}
}

func TestRuntimeAppleRoutingPinsSlashIDsToAppleLocal(t *testing.T) {
	clearDeploymentCredentialEnv(t)
	tmp := t.TempDir()
	t.Setenv("HOME", tmp)

	appleModels := make(chan string, 1)
	appleSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/health":
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"status":"fm serve is running","models":[{"name":"system","available":true}]}`))
		case "/v1/chat/completions":
			var body struct {
				Model string `json:"model"`
			}
			if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
				http.Error(w, err.Error(), http.StatusBadRequest)
				return
			}
			appleModels <- body.Model
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"id":"apple-resp","model":"system","choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}`))
		default:
			http.NotFound(w, r)
		}
	}))
	defer appleSrv.Close()
	var openRouterCalls atomic.Int32
	openRouterSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		openRouterCalls.Add(1)
		http.Error(w, "OpenRouter should not serve runtime Apple models", http.StatusInternalServerError)
	}))
	defer openRouterSrv.Close()
	t.Setenv("APPLE_FM_BASE_URL", appleSrv.URL)

	cfg := Config{
		Deployments: map[string]DeploymentConfig{
			"openrouter": {APIKey: "sk-openrouter", BaseURL: openRouterSrv.URL},
		},
		Routing: &RoutingPolicy{
			Default: []RoutingStage{{Deployments: []DeploymentChoice{{DeploymentID: "openrouter", Weight: 100}}}},
			Models: map[string][]RoutingStage{
				"apple/system": {{Deployments: []DeploymentChoice{{DeploymentID: "openrouter", Weight: 100}}}},
			},
		},
	}
	client, err := newLangdagClientForModelsWithCatalog(newLangdagClientForModelsWithCatalogOptions{
		cfg:     cfg,
		models:  []ModelDef{appleRuntimeModel("system")},
		catalog: langdag.ReferenceCatalogV1(),
	})
	if err != nil {
		t.Fatalf("newLangdagClientForModelsWithCatalog error: %v", err)
	}
	if client == nil {
		t.Fatal("client = nil, want configured provider client")
	}
	defer client.Close()

	resp, err := client.Provider().Complete(context.Background(), &types.CompletionRequest{
		Model:     "apple/system",
		Messages:  []types.Message{{Role: "user", Content: json.RawMessage(`"hello"`)}},
		MaxTokens: 1,
	})
	if err != nil {
		t.Fatalf("Complete apple/system error: %v", err)
	}
	if resp.Provider != "apple-local" {
		t.Fatalf("response provider = %q, want apple-local", resp.Provider)
	}
	if resp.ModelResolution == nil || resp.ModelResolution.DeploymentID != "apple-local" || resp.ModelResolution.NativeModelID != "system" {
		t.Fatalf("ModelResolution = %+v, want apple-local/system", resp.ModelResolution)
	}
	select {
	case model := <-appleModels:
		if model != "system" {
			t.Fatalf("Apple request model = %q, want system", model)
		}
	default:
		t.Fatal("Apple completion endpoint was not called")
	}
	if openRouterCalls.Load() != 0 {
		t.Fatalf("OpenRouter was called %d times for runtime Apple model", openRouterCalls.Load())
	}
}

func TestRuntimeAppleAvailableModelsPinsExplicitOpenRouterRouting(t *testing.T) {
	clearDeploymentCredentialEnv(t)

	openRouterRoute := []RoutingStage{{Deployments: []DeploymentChoice{{DeploymentID: "openrouter", Weight: 100}}}}
	for _, tc := range []struct {
		name    string
		routing *RoutingPolicy
	}{
		{
			name:    "default",
			routing: &RoutingPolicy{Default: openRouterRoute},
		},
		{
			name: "provider",
			routing: &RoutingPolicy{Providers: map[string][]RoutingStage{
				"apple": openRouterRoute,
			}},
		},
		{
			name: "model",
			routing: &RoutingPolicy{Models: map[string][]RoutingStage{
				"apple/system": openRouterRoute,
			}},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cfg := Config{
				Deployments: map[string]DeploymentConfig{
					"openrouter": {APIKey: "sk-openrouter"},
				},
				Routing: tc.routing,
			}
			models := []ModelDef{appleRuntimeModel("system")}

			available := cfg.availableModels(models)
			if len(available) != 1 || available[0].ID != "apple/system" {
				t.Fatalf("available = %+v, want runtime apple/system visible", available)
			}
			if len(available[0].Deployments) != 1 || available[0].Deployments[0].DeploymentID != "apple-local" {
				t.Fatalf("available deployments = %+v, want apple-local only", available[0].Deployments)
			}
			if diagnostics := routingDiagnosticsForConfigModels(configModelsOptions{cfg: cfg, models: models}); len(diagnostics) != 0 {
				t.Fatalf("routing diagnostics = %+v, want runtime Apple route pin to suppress raw OpenRouter route diagnostics", diagnostics)
			}
		})
	}
}

func TestRuntimeAppleAvailableModelsDoesNotPinStaticAppleRows(t *testing.T) {
	clearDeploymentCredentialEnv(t)

	runtimeSystem := appleRuntimeModel("system")
	staticSystem := appleRuntimeModel("system")
	staticSystem.RuntimeDiscovered = false
	staticPCC := appleRuntimeModel("pcc")
	staticPCC.RuntimeDiscovered = false
	cfg := Config{
		Deployments: map[string]DeploymentConfig{
			"openrouter":  {APIKey: "sk-openrouter"},
			"apple-local": {BaseURL: appleFMDefaultBaseURL},
		},
		Routing: &RoutingPolicy{
			Default: []RoutingStage{{Deployments: []DeploymentChoice{{DeploymentID: "openrouter", Weight: 100}}}},
			Models: map[string][]RoutingStage{
				"apple/system": {{Deployments: []DeploymentChoice{{DeploymentID: "openrouter", Weight: 100}}}},
			},
		},
	}

	available := cfg.availableModels([]ModelDef{runtimeSystem, staticSystem, staticPCC})
	if len(available) != 1 || available[0].ID != "apple/system" || !available[0].RuntimeDiscovered {
		t.Fatalf("available = %+v, want only runtime apple/system pinned visible", available)
	}
	if len(available[0].Deployments) != 1 || available[0].Deployments[0].DeploymentID != "apple-local" {
		t.Fatalf("runtime Apple deployments = %+v, want apple-local only", available[0].Deployments)
	}
}

func TestAppleModelsMsgRefreshesExistingConfiguredProviderClient(t *testing.T) {
	clearDeploymentCredentialEnv(t)
	tmp := t.TempDir()
	t.Setenv("HOME", tmp)
	appleSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/health" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"status":"fm serve is running","models":[{"name":"system","available":true}]}`))
	}))
	defer appleSrv.Close()
	openRouterSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/models" {
			http.Error(w, "unexpected OpenRouter request", http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"data":[]}`))
	}))
	defer openRouterSrv.Close()
	t.Setenv("APPLE_FM_BASE_URL", appleSrv.URL)

	cfg := Config{Deployments: map[string]DeploymentConfig{"openrouter": {APIKey: "sk-openrouter", BaseURL: openRouterSrv.URL}}}
	existing, err := newLangdagClient(cfg)
	if err != nil {
		t.Fatalf("newLangdagClient error: %v", err)
	}
	defer existing.Close()

	app := &App{
		config:          cfg,
		langdagClient:   existing,
		langdagProvider: ProviderOpenRouter,
		resultCh:        make(chan any, 1),
	}
	app.handleResult(appleModelsMsg{models: []ModelDef{appleRuntimeModel("system")}})

	select {
	case result := <-app.resultCh:
		msg, ok := result.(langdagReadyMsg)
		if !ok {
			t.Fatalf("result = %T, want langdagReadyMsg", result)
		}
		if msg.err != nil {
			t.Fatalf("langdagReadyMsg err = %v", msg.err)
		}
		if msg.client == nil || msg.provider != ProviderOpenRouter {
			t.Fatalf("langdagReadyMsg client/provider = %v/%q, want non-nil/openrouter", msg.client, msg.provider)
		}
		defer msg.client.Close()
		if !providerHasModel(msg.client.Provider().Models(), "apple/system") {
			t.Fatalf("refreshed provider models do not include apple/system")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for langdagReadyMsg")
	}
}

func TestNilLangdagReadyMsgDoesNotClearExistingAppleClient(t *testing.T) {
	existing := newTestClient("ok")
	defer existing.Close()
	app := &App{
		langdagClient:   existing,
		langdagProvider: ProviderApple,
	}

	app.handleResult(langdagReadyMsg{})

	if app.langdagClient != existing {
		t.Fatal("nil langdagReadyMsg cleared existing client")
	}
	if app.langdagProvider != ProviderApple {
		t.Fatalf("langdagProvider = %q, want apple", app.langdagProvider)
	}
}

func TestAppleModelsMsgDisappearedThenNilLangdagReadyClearsRuntimeAppleClient(t *testing.T) {
	existing := newTestClient("ok")
	app := &App{
		config:              Config{},
		models:              []ModelDef{appleRuntimeModel("system")},
		langdagClient:       existing,
		langdagProvider:     ProviderApple,
		langdagRuntimeApple: true,
		resultCh:            make(chan any, 1),
	}

	app.handleResult(appleModelsMsg{})
	select {
	case result := <-app.resultCh:
		msg, ok := result.(langdagReadyMsg)
		if !ok {
			t.Fatalf("result = %T, want langdagReadyMsg", result)
		}
		if msg.client != nil || msg.provider != "" || msg.runtimeApple {
			t.Fatalf("langdagReadyMsg = client:%v provider:%q runtimeApple:%v, want nil/empty/false", msg.client, msg.provider, msg.runtimeApple)
		}
		app.handleResult(msg)
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for langdagReadyMsg")
	}
	if app.langdagClient != nil {
		t.Fatal("stale runtime Apple langdag client was not cleared")
	}
	if app.langdagProvider != "" || app.langdagRuntimeApple {
		t.Fatalf("langdag state = provider:%q runtimeApple:%v, want cleared", app.langdagProvider, app.langdagRuntimeApple)
	}
}

func TestStaleNonAppleLangdagReadyMsgDoesNotReplaceRuntimeAppleClient(t *testing.T) {
	existing := newTestClient("ok")
	defer existing.Close()
	stale := newTestClient("stale")
	app := &App{
		models:              []ModelDef{appleRuntimeModel("system")},
		langdagClient:       existing,
		langdagProvider:     ProviderOpenRouter,
		langdagRuntimeApple: true,
	}

	app.handleResult(langdagReadyMsg{client: stale, provider: ProviderOpenRouter})

	if app.langdagClient != existing {
		t.Fatal("stale non-Apple langdagReadyMsg replaced runtime Apple client")
	}
	if !app.langdagRuntimeApple {
		t.Fatal("langdagRuntimeApple was cleared by stale non-Apple langdagReadyMsg")
	}
}

func TestAppleDefaultActiveModelPrefersSystemRegardlessOfHealthOrder(t *testing.T) {
	models := []ModelDef{appleRuntimeModel("pcc"), appleRuntimeModel("system")}
	if got := (Config{}).resolveActiveModel(models); got != "apple/system" {
		t.Fatalf("resolveActiveModel = %q, want apple/system", got)
	}
}

func TestDraftApplePickerResultsDoNotMutateRuntimeModels(t *testing.T) {
	app := &App{
		cfgActive: true,
		cfgDraft:  Config{},
		models:    []ModelDef{appleRuntimeModel("system")},
	}
	before := append([]ModelDef(nil), app.models...)

	app.handleResult(draftAppleModelsMsg{
		models:       []ModelDef{appleRuntimeModel("pcc")},
		getCurrentID: func() string { return "" },
		onSelect:     func(string) {},
	})

	if len(app.models) != len(before) || app.models[0].ID != before[0].ID {
		t.Fatalf("runtime models mutated by draft fetch: before=%+v after=%+v", before, app.models)
	}
	if findModelByID(findModelByIDOptions{models: app.menuModels, id: "apple/pcc"}) == nil {
		t.Fatalf("draft picker models = %+v, want apple/pcc available in picker", app.menuModels)
	}
}

func TestDynamicAppleRoutingValidationDoesNotReportUnavailableDeployment(t *testing.T) {
	model := appleRuntimeModel("system")
	cfg := Config{
		Routing: &RoutingPolicy{
			Models: map[string][]RoutingStage{
				"apple/system": {{
					Deployments: []DeploymentChoice{{DeploymentID: "apple-local", Weight: 100}},
				}},
			},
		},
	}

	index := routingValidationIndexForConfigModels(configModelsOptions{cfg: cfg, models: []ModelDef{model}})
	if !index.AvailableDeployments["apple-local"] {
		t.Fatalf("AvailableDeployments = %+v, want apple-local", index.AvailableDeployments)
	}
	if !index.EligibleDeploymentsByModel["apple/system"]["apple-local"] {
		t.Fatalf("EligibleDeploymentsByModel = %+v, want apple-local for apple/system", index.EligibleDeploymentsByModel)
	}
	for _, diagnostic := range routingDiagnosticsForConfigModels(configModelsOptions{cfg: cfg, models: []ModelDef{model}}) {
		if diagnostic.Code == "unavailable_deployment" {
			t.Fatalf("unexpected unavailable_deployment diagnostic: %+v", diagnostic)
		}
	}
}

func TestAppleModelsMsgRemovesStaleAppleDynamicModels(t *testing.T) {
	current := []ModelDef{{Provider: ProviderApple, OwnerProvider: ProviderApple, ID: "apple/system"}}
	app := &App{models: current}

	app.handleResult(appleModelsMsg{})
	if findModelByID(findModelByIDOptions{models: app.models, id: "apple/system"}) != nil {
		t.Fatal("stale Apple dynamic model was preserved after empty Apple result")
	}
}

func appleRuntimeModel(id string) ModelDef {
	return ModelDef{
		Provider:          ProviderApple,
		OwnerProvider:     ProviderApple,
		ID:                "apple/" + id,
		CanonicalID:       "apple/" + id,
		RuntimeDiscovered: true,
		Deployments: []ModelDeploymentDef{{
			DeploymentID:  "apple-local",
			ProviderID:    ProviderApple,
			NativeModelID: id,
			OfferingID:    "apple-local:" + id,
		}},
	}
}

func providerHasModel(models []types.ModelInfo, id string) bool {
	for _, model := range models {
		if model.ID == id {
			return true
		}
	}
	return false
}
