package main

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

func TestPhase12ScopedProviderRouteDoesNotHideUnmatchedModels(t *testing.T) {
	cfg := Config{
		Deployments: map[string]DeploymentConfig{
			"openai-direct": {APIKey: "sk-openai"},
			"openrouter":    {APIKey: "sk-or"},
		},
		Routing: &RoutingPolicy{
			Providers: map[string][]RoutingStage{
				"openai": {{Deployments: []DeploymentChoice{{DeploymentID: "openai-direct", Weight: 100}}}},
			},
		},
	}
	models := []ModelDef{
		{
			Provider:      ProviderOpenAI,
			OwnerProvider: ProviderOpenAI,
			ID:            "openai/gpt-4.1-2025-04-14",
			Deployments: []ModelDeploymentDef{
				{DeploymentID: "openai-direct", NativeModelID: "gpt-4.1-2025-04-14"},
				{DeploymentID: "openrouter", NativeModelID: "openai/gpt-4.1-2025-04-14"},
			},
		},
		{
			Provider:      ProviderOpenRouter,
			OwnerProvider: "z-ai",
			ID:            "z-ai/glm-4.5-air:free",
			Deployments:   []ModelDeploymentDef{{DeploymentID: "openrouter", NativeModelID: "z-ai/glm-4.5-air:free"}},
		},
	}

	available := cfg.availableModels(models)
	if len(available) != 2 {
		t.Fatalf("available models = %+v, want both matching and unmatched models", available)
	}
	openai := findModelByID(findModelByIDOptions{models: available, id: "openai/gpt-4.1-2025-04-14"})
	if openai == nil || len(openai.Deployments) != 1 || openai.Deployments[0].DeploymentID != "openai-direct" {
		t.Fatalf("openai model should be constrained by provider rule: %+v", openai)
	}
	zai := findModelByID(findModelByIDOptions{models: available, id: "z-ai/glm-4.5-air:free"})
	if zai == nil || len(zai.Deployments) != 1 || zai.Deployments[0].DeploymentID != "openrouter" {
		t.Fatalf("unmatched model should keep automatic eligible deployments: %+v", zai)
	}
}

func TestPhase12ScopedModelRouteDoesNotHideUnmatchedModels(t *testing.T) {
	cfg := Config{
		Deployments: map[string]DeploymentConfig{
			"openai-direct": {APIKey: "sk-openai"},
			"openrouter":    {APIKey: "sk-or"},
		},
		Routing: &RoutingPolicy{
			Models: map[string][]RoutingStage{
				"openai/gpt-4.1-2025-04-14": {{Deployments: []DeploymentChoice{{DeploymentID: "openai-direct", Weight: 100}}}},
			},
		},
	}
	models := []ModelDef{
		{
			Provider:      ProviderOpenAI,
			OwnerProvider: ProviderOpenAI,
			ID:            "openai/gpt-4.1-2025-04-14",
			Deployments: []ModelDeploymentDef{
				{DeploymentID: "openai-direct", NativeModelID: "gpt-4.1-2025-04-14"},
				{DeploymentID: "openrouter", NativeModelID: "openai/gpt-4.1-2025-04-14"},
			},
		},
		{
			Provider:      ProviderOpenAI,
			OwnerProvider: ProviderOpenAI,
			ID:            "openai/gpt-4.1-mini-2025-04-14",
			Deployments: []ModelDeploymentDef{
				{DeploymentID: "openai-direct", NativeModelID: "gpt-4.1-mini-2025-04-14"},
				{DeploymentID: "openrouter", NativeModelID: "openai/gpt-4.1-mini-2025-04-14"},
			},
		},
	}

	available := cfg.availableModels(models)
	targeted := findModelByID(findModelByIDOptions{models: available, id: "openai/gpt-4.1-2025-04-14"})
	if targeted == nil || len(targeted.Deployments) != 1 || targeted.Deployments[0].DeploymentID != "openai-direct" {
		t.Fatalf("targeted model should be constrained by model rule: %+v", targeted)
	}
	unmatched := findModelByID(findModelByIDOptions{models: available, id: "openai/gpt-4.1-mini-2025-04-14"})
	if unmatched == nil || len(unmatched.Deployments) != 2 {
		t.Fatalf("unmatched same-provider model should keep automatic deployments: %+v", unmatched)
	}
}

func TestPhase12RoutingDiagnosticsDoNotRequireDefaultRoute(t *testing.T) {
	cfg := Config{
		Deployments: map[string]DeploymentConfig{
			"anthropic-direct": {APIKey: "sk-ant"},
			"openrouter":       {APIKey: "sk-or"},
		},
		Routing: &RoutingPolicy{
			Providers: map[string][]RoutingStage{
				"openai": {{Deployments: []DeploymentChoice{{DeploymentID: "anthropic-direct", Weight: 100}}}},
			},
		},
	}
	models := []ModelDef{
		{
			Provider:      ProviderOpenAI,
			OwnerProvider: ProviderOpenAI,
			ID:            "openai/gpt-4.1-2025-04-14",
			Deployments:   []ModelDeploymentDef{{DeploymentID: "openai-direct"}},
		},
		{
			Provider:      ProviderOpenRouter,
			OwnerProvider: "z-ai",
			ID:            "z-ai/glm-4.5-air:free",
			Deployments:   []ModelDeploymentDef{{DeploymentID: "openrouter"}},
		},
	}

	diagnostics := routingDiagnosticsForConfigModels(configModelsOptions{cfg: cfg, models: models})
	got := diagnosticPathCodes(diagnostics)
	want := []string{
		"routing.effective.provider.openai/gpt-4.1-2025-04-14[0].deployments:no_eligible_deployments",
		"routing.effective.provider.openai/gpt-4.1-2025-04-14[0].deployments[0].deployment_id:ineligible_deployment",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("diagnostics = %+v, want %+v\nfull diagnostics: %+v", got, want, diagnostics)
	}
	for _, diagnostic := range diagnostics {
		if diagnostic.Code == "no_effective_route" {
			t.Fatalf("unmatched models should not produce no-effective-route diagnostics: %+v", diagnostics)
		}
	}
}

func TestPhase12ExplicitAdvancedDefaultRouteStillApplies(t *testing.T) {
	cfg := Config{
		Deployments: map[string]DeploymentConfig{
			"openai-direct": {APIKey: "sk-openai"},
			"openrouter":    {APIKey: "sk-or"},
		},
		Routing: &RoutingPolicy{
			Default: []RoutingStage{{Deployments: []DeploymentChoice{{DeploymentID: "openrouter", Weight: 100}}}},
		},
	}
	models := []ModelDef{{
		Provider:      ProviderOpenAI,
		OwnerProvider: ProviderOpenAI,
		ID:            "openai/gpt-4.1-2025-04-14",
		Deployments: []ModelDeploymentDef{
			{DeploymentID: "openai-direct", NativeModelID: "gpt-4.1-2025-04-14"},
			{DeploymentID: "openrouter", NativeModelID: "openai/gpt-4.1-2025-04-14"},
		},
	}}

	available := cfg.availableModels(models)
	if len(available) != 1 || len(available[0].Deployments) != 1 || available[0].Deployments[0].DeploymentID != "openrouter" {
		t.Fatalf("advanced default route should still constrain unmatched models: %+v", available)
	}
}

func TestPhase12ExplicitEmptyAdvancedDefaultRouteIsPreserved(t *testing.T) {
	cfg := normalizeLoadedConfig(Config{Routing: &RoutingPolicy{Default: []RoutingStage{}}})
	if cfg.Routing == nil || cfg.Routing.Default == nil || len(cfg.Routing.Default) != 0 {
		t.Fatalf("explicit empty routing.default was not preserved: %+v", cfg.Routing)
	}
	if routingPolicyIsEmpty(cfg.Routing) {
		t.Fatalf("explicit empty routing.default should be treated as an advanced route override")
	}
	_, source, ok := cfg.Routing.routeFor(routeForOptions{canonicalModelID: "openai/gpt-4.1-2025-04-14", providerID: "openai"})
	if !ok || source != RouteSourceDefault {
		t.Fatalf("explicit empty routing.default routeFor source=%q ok=%v", source, ok)
	}
	diagnostics := cfg.Routing.validate(RoutingValidationIndex{})
	got := diagnosticPathCodes(diagnostics)
	want := []string{"routing.default:empty_override"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("diagnostics = %+v, want %+v\nfull diagnostics: %+v", got, want, diagnostics)
	}
	data, err := json.Marshal(deploymentAwareConfigFromLegacyConfig(cfg))
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}
	if !strings.Contains(string(data), `"default":[]`) {
		t.Fatalf("explicit empty routing.default was not preserved in JSON: %s", data)
	}
}

func TestPhase12RoutingTabShowsScopedActionsAndNoDefaultStep(t *testing.T) {
	app := phase9RoutingApp()
	rows := strings.Join(app.buildConfigRows(), "\n")

	expectRowsContainAll(t, rows,
		"Routing rules are global and scoped to a provider or model.",
		"Unmatched models use the advanced JSON default route.",
		"Advanced JSON default route is configured.",
		"Provider openai: primary openai-direct",
		"Model openai/gpt-4.1-2025-04-14: primary openrouter",
		"Add rule",
		"Delete rule",
		"A=add rule",
		"D=delete rule",
		"Ctrl+E=edit global JSON",
	)
	expectRowsNotContainAny(t, rows,
		"Default:",
		"routing JSON",
		`"default": [`,
		"Route syntax:",
		"Default Route:",
	)
}

func TestPhase12RoutingTabDefaultOnlySummaryIsAccurate(t *testing.T) {
	app := &App{
		cfgTab: 1,
		cfgDraft: Config{Routing: &RoutingPolicy{Default: []RoutingStage{{
			Deployments: []DeploymentChoice{{DeploymentID: "openrouter", Weight: 100}},
		}}}},
	}

	rows := strings.Join(app.buildConfigRows(), "\n")
	expectRowsContainAll(t, rows,
		"Unmatched models use the advanced JSON default route.",
		"Advanced JSON default route is configured.",
		"No scoped routing rules. The advanced JSON default route handles unmatched models.",
	)
	expectRowsNotContainAny(t, rows,
		"Unmatched models use the default model provider/deployment automatically.",
		"No routing rules. Using default model provider/deployment.",
	)
}

func TestPhase12RoutingAddAndDeleteRuleActions(t *testing.T) {
	app := &App{
		headless: true,
		cfgTab:   1,
		cfgDraft: Config{Deployments: map[string]DeploymentConfig{
			"openai-direct": {APIKey: "sk-openai"},
			"openrouter":    {APIKey: "sk-or"},
		}},
		models: []ModelDef{{
			Provider:      ProviderOpenAI,
			OwnerProvider: ProviderOpenAI,
			ID:            "openai/gpt-4.1-2025-04-14",
			Deployments: []ModelDeploymentDef{
				{DeploymentID: "openai-direct"},
				{DeploymentID: "openrouter"},
			},
		}},
	}

	app.openRoutingAddRuleScopeMenu()
	app.menuAction(0) // Provider rule.
	app.menuAction(menuLineIndex(t, app.menuLines, "openai"))
	app.menuAction(menuLineIndex(t, app.menuLines, "openai-direct"))
	app.menuAction(menuLineIndex(t, app.menuLines, "openrouter"))
	app.menuAction(0) // Save review.

	if app.cfgDraft.Routing == nil || len(app.cfgDraft.Routing.Providers["openai"]) != 2 {
		t.Fatalf("provider rule was not saved: %+v", app.cfgDraft.Routing)
	}
	if app.cfgDraft.Routing.Providers["openai"][0].Deployments[0].DeploymentID != "openai-direct" ||
		app.cfgDraft.Routing.Providers["openai"][1].Deployments[0].DeploymentID != "openrouter" {
		t.Fatalf("provider rule stages = %+v", app.cfgDraft.Routing.Providers["openai"])
	}

	app.openRoutingDeleteRuleMenu()
	app.menuAction(menuLineIndex(t, app.menuLines, "Provider openai"))
	if app.cfgDraft.Routing != nil {
		t.Fatalf("provider rule was not deleted: %+v", app.cfgDraft.Routing)
	}
}

func TestPhase12RoutingAddModelRuleNoFallbackPath(t *testing.T) {
	app := &App{
		headless: true,
		cfgTab:   1,
		cfgDraft: Config{Deployments: map[string]DeploymentConfig{
			"openai-direct": {APIKey: "sk-openai"},
			"openrouter":    {APIKey: "sk-or"},
		}},
		models: []ModelDef{{
			Provider:      ProviderOpenAI,
			OwnerProvider: ProviderOpenAI,
			ID:            "openai/gpt-4.1-2025-04-14",
			Deployments: []ModelDeploymentDef{
				{DeploymentID: "openai-direct"},
				{DeploymentID: "openrouter"},
			},
		}},
	}

	app.openRoutingAddRuleScopeMenu()
	app.menuAction(1) // Model rule.
	app.menuAction(menuLineIndex(t, app.menuLines, "openai/gpt-4.1-2025-04-14"))
	app.menuAction(menuLineIndex(t, app.menuLines, "openai-direct"))
	app.menuAction(menuLineIndex(t, app.menuLines, "No fallback"))
	app.menuAction(0) // Save review.

	stages := app.cfgDraft.Routing.Models["openai/gpt-4.1-2025-04-14"]
	if len(stages) != 1 || stages[0].Deployments[0].DeploymentID != "openai-direct" {
		t.Fatalf("model rule stages = %+v", stages)
	}
}

func TestPhase12RoutingTabKeyDispatchOpensRuleMenus(t *testing.T) {
	app := &App{
		headless: true,
		cfgTab:   1,
		cfgDraft: Config{
			Deployments: map[string]DeploymentConfig{"openai-direct": {APIKey: "sk-openai"}},
			Routing: &RoutingPolicy{Providers: map[string][]RoutingStage{
				"openai": {{Deployments: []DeploymentChoice{{DeploymentID: "openai-direct", Weight: 100}}}},
			}},
		},
		models: []ModelDef{{
			Provider:      ProviderOpenAI,
			OwnerProvider: ProviderOpenAI,
			ID:            "openai/gpt-4.1-2025-04-14",
			Deployments:   []ModelDeploymentDef{{DeploymentID: "openai-direct"}},
		}},
	}

	app.handleConfigByte(handleConfigByteOptions{ch: 'a'})
	if !app.menuActive || app.menuHeader != "Add routing rule" {
		t.Fatalf("A key did not open add-rule menu: active=%v header=%q lines=%+v", app.menuActive, app.menuHeader, app.menuLines)
	}
	app.menuActive = false
	app.handleConfigByte(handleConfigByteOptions{ch: 'd'})
	if !app.menuActive || app.menuHeader != "Delete routing rule" {
		t.Fatalf("D key did not open delete-rule menu: active=%v header=%q lines=%+v", app.menuActive, app.menuHeader, app.menuLines)
	}
}

func TestPhase12ProviderRuleCandidatesUseAvailableCommonDeployments(t *testing.T) {
	cfg := Config{Deployments: map[string]DeploymentConfig{
		"openai-direct": {APIKey: "sk-openai"},
		"openrouter":    {APIKey: "sk-or"},
	}}
	models := []ModelDef{
		{
			Provider:      ProviderOpenAI,
			OwnerProvider: ProviderOpenAI,
			ID:            "openai/gpt-a",
			Deployments: []ModelDeploymentDef{
				{DeploymentID: "openai-direct"},
				{DeploymentID: "openrouter"},
			},
		},
		{
			Provider:      ProviderOpenAI,
			OwnerProvider: ProviderOpenAI,
			ID:            "openai/gpt-b",
			Deployments:   []ModelDeploymentDef{{DeploymentID: "openrouter"}},
		},
		{
			Provider:      "google",
			OwnerProvider: "google",
			ID:            "google/gemini-2.5-pro",
			Deployments:   []ModelDeploymentDef{{DeploymentID: "gemini-direct"}},
		},
	}

	providers := routingProviderCandidates(routingProviderCandidatesOptions{cfg: cfg, models: models})
	if !reflect.DeepEqual(providers, []string{"openai"}) {
		t.Fatalf("provider candidates = %+v, want openai only", providers)
	}
	deployments := routingEligibleDeploymentCandidates(routingEligibleDeploymentCandidatesOptions{
		cfg:    cfg,
		models: models,
		draft:  routingAddRuleDraft{scope: routingScopeProvider, key: "openai"},
	})
	if !reflect.DeepEqual(deployments, []string{"openrouter"}) {
		t.Fatalf("provider deployment candidates = %+v, want common openrouter only", deployments)
	}
}

func menuLineIndex(t *testing.T, lines []string, value string) int {
	t.Helper()
	for i, line := range lines {
		if line == value {
			return i
		}
	}
	t.Fatalf("menu line %q not found in %+v", value, lines)
	return -1
}
