package main

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

func TestScopedRoutingScopedProviderRouteDoesNotHideUnmatchedModels(t *testing.T) {
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

func TestScopedRoutingScopedModelRouteDoesNotHideUnmatchedModels(t *testing.T) {
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

func TestScopedRoutingRoutingDiagnosticsDoNotRequireDefaultRoute(t *testing.T) {
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

func TestScopedRoutingExplicitAdvancedDefaultRouteStillApplies(t *testing.T) {
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

func TestScopedRoutingExplicitEmptyAdvancedDefaultRouteIsPreserved(t *testing.T) {
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
	langdagPolicy := langdagRoutingPolicyFromConfig(cfg.Routing)
	if langdagPolicy == nil || langdagPolicy.Default == nil || len(langdagPolicy.Default) != 0 {
		t.Fatalf("explicit empty routing.default was not preserved for langdag: %+v", langdagPolicy)
	}
}

func TestScopedRoutingRoutingTabShowsScopedActionsAndNoDefaultStep(t *testing.T) {
	app := routingPreviewApp()
	rows := strings.Join(app.buildConfigRows(), "\n")

	expectRowsContainAll(t, rows,
		"Set custom routing, per provider or model (advanced).",
		"Provider openai: primary openai-direct",
		"Model openai/gpt-4.1-2025-04-14: primary openrouter",
		"Add rule",
	)
	expectRowsNotContainAny(t, rows,
		"Unmatched models use the advanced JSON default route.",
		"Advanced JSON default route is configured.",
		"Delete rule",
		"A=add rule",
		"D=delete rule",
		"Ctrl+E=edit global JSON",
		"Default:",
		"routing JSON",
		`"default": [`,
		"Route syntax:",
		"Default Route:",
	)
}

func TestScopedRoutingRoutingTabDefaultOnlySummaryIsAccurate(t *testing.T) {
	app := &App{
		cfgTab: cfgTabRouting,
		cfgDraft: Config{Routing: &RoutingPolicy{Default: []RoutingStage{{
			Deployments: []DeploymentChoice{{DeploymentID: "openrouter", Weight: 100}},
		}}}},
	}

	rows := strings.Join(app.buildConfigRows(), "\n")
	expectRowsContainAll(t, rows,
		"Set custom routing, per provider or model (advanced).",
	)
	expectRowsNotContainAny(t, rows,
		"Unmatched models use the advanced JSON default route.",
		"Advanced JSON default route is configured.",
		"No scoped routing rules. The advanced JSON default route handles unmatched models.",
		"Unmatched models use the default model provider/deployment automatically.",
		"No routing rules. Using default model provider/deployment.",
	)
}

func TestScopedRoutingRoutingAddAndDeleteRuleActions(t *testing.T) {
	app := &App{
		headless: true,
		cfgTab:   cfgTabRouting,
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

	app.cfgCursor = routingFieldIndex(t, app.routingTabFields(), "Provider openai")
	app.handleConfigByte(handleConfigByteOptions{ch: '\r'})
	if !app.menuActive || app.menuHeader != "Provider openai" {
		t.Fatalf("provider row did not open contextual rule menu: active=%v header=%q lines=%+v", app.menuActive, app.menuHeader, app.menuLines)
	}
	app.menuAction(menuLineIndex(t, app.menuLines, "Delete rule"))
	if app.cfgDraft.Routing != nil {
		t.Fatalf("provider rule was not deleted: %+v", app.cfgDraft.Routing)
	}
}

func TestScopedRoutingRoutingAddModelRuleNoFallbackPath(t *testing.T) {
	app := &App{
		headless: true,
		cfgTab:   cfgTabRouting,
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

func TestScopedRoutingRoutingTabEnterSelectsAddAndRuleActions(t *testing.T) {
	app := &App{
		headless: true,
		cfgTab:   cfgTabRouting,
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

	app.cfgCursor = 0
	app.handleConfigByte(handleConfigByteOptions{ch: '\r'})
	if !app.menuActive || app.menuHeader != "Add routing rule" {
		t.Fatalf("Enter on Add rule did not open add-rule menu: active=%v header=%q lines=%+v", app.menuActive, app.menuHeader, app.menuLines)
	}
	app.menuActive = false
	app.cfgCursor = routingFieldIndex(t, app.routingTabFields(), "Provider openai")
	app.handleConfigByte(handleConfigByteOptions{ch: '\r'})
	if !app.menuActive || app.menuHeader != "Provider openai" {
		t.Fatalf("Enter on rule did not open contextual menu: active=%v header=%q lines=%+v", app.menuActive, app.menuHeader, app.menuLines)
	}
	expectRowsContainAll(t, strings.Join(app.menuLines, "\n"), "Replace rule", "Delete rule", "Cancel")
}

func TestScopedRoutingRoutingTabArrowNavigationWrapsSelectableRows(t *testing.T) {
	app := &App{
		headless: true,
		cfgTab:   cfgTabRouting,
		cfgDraft: Config{Routing: &RoutingPolicy{Providers: map[string][]RoutingStage{
			"openai": {{Deployments: []DeploymentChoice{{DeploymentID: "openai-direct", Weight: 100}}}},
		}}},
	}

	sendConfigArrow(app, 'B')
	if got := app.routingTabFields()[app.cfgCursor].label; got != "Provider openai" {
		t.Fatalf("Down should select provider rule, got %q", got)
	}
	sendConfigArrow(app, 'B')
	if got := app.routingTabFields()[app.cfgCursor].label; got != "Add rule" {
		t.Fatalf("Down should wrap back to Add rule, got %q", got)
	}
	sendConfigArrow(app, 'A')
	if got := app.routingTabFields()[app.cfgCursor].label; got != "Provider openai" {
		t.Fatalf("Up should wrap to provider rule, got %q", got)
	}
	sendConfigArrow(app, 'A')
	if got := app.routingTabFields()[app.cfgCursor].label; got != "Add rule" {
		t.Fatalf("Up from provider should select Add rule, got %q", got)
	}
}

func TestScopedRoutingRoutingTabShortcutActionsAreUnsupported(t *testing.T) {
	called := false
	app := &App{
		headless: true,
		cfgTab:   cfgTabRouting,
		cfgDraft: Config{Routing: &RoutingPolicy{Providers: map[string][]RoutingStage{
			"openai": {{Deployments: []DeploymentChoice{{DeploymentID: "openai-direct", Weight: 100}}}},
		}}},
		configJSONEditor: func(string) error {
			called = true
			return nil
		},
	}

	for _, ch := range []byte{'a', 'A', 'd', 'D', 0x05} {
		app.menuActive = false
		app.handleConfigByte(handleConfigByteOptions{ch: ch})
		if app.menuActive {
			t.Fatalf("shortcut %q unexpectedly opened menu %q", ch, app.menuHeader)
		}
	}
	if called {
		t.Fatal("Ctrl+E should not open the global JSON editor from the routing tab")
	}
}

func TestScopedRoutingRoutingAddCandidatesExcludeExistingRules(t *testing.T) {
	cfg := Config{
		Deployments: map[string]DeploymentConfig{
			"openai-direct": {APIKey: "sk-openai"},
			"openrouter":    {APIKey: "sk-or"},
		},
		Routing: &RoutingPolicy{
			Providers: map[string][]RoutingStage{
				"openai": {{Deployments: []DeploymentChoice{{DeploymentID: "openai-direct", Weight: 100}}}},
			},
			Models: map[string][]RoutingStage{
				"openai/gpt-a": {{Deployments: []DeploymentChoice{{DeploymentID: "openrouter", Weight: 100}}}},
			},
		},
	}
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
			Deployments: []ModelDeploymentDef{
				{DeploymentID: "openai-direct"},
				{DeploymentID: "openrouter"},
			},
		},
	}

	providers := routingProviderCandidates(routingProviderCandidatesOptions{cfg: cfg, models: models})
	if len(providers) != 0 {
		t.Fatalf("provider candidates should exclude existing provider rules, got %+v", providers)
	}
	modelCandidates := routingModelCandidates(routingModelCandidatesOptions{cfg: cfg, models: models})
	got := make([]string, 0, len(modelCandidates))
	for _, model := range modelCandidates {
		got = append(got, model.ID)
	}
	if !reflect.DeepEqual(got, []string{"openai/gpt-b"}) {
		t.Fatalf("model candidates should exclude existing model rules, got %+v", got)
	}
}

func TestScopedRoutingConfigSaveHintOnlyAppearsWhenDirty(t *testing.T) {
	app := &App{
		cfgTab:       cfgTabRouting,
		globalConfig: Config{},
		cfgDraft:     Config{},
	}
	cleanRows := strings.Join(app.buildConfigRows(), "\n")
	expectRowsNotContainAny(t, cleanRows, "Ctrl+S=save")

	app.cfgDraft.Routing = &RoutingPolicy{Providers: map[string][]RoutingStage{
		"openai": {{Deployments: []DeploymentChoice{{DeploymentID: "openai-direct", Weight: 100}}}},
	}}
	dirtyRows := strings.Join(app.buildConfigRows(), "\n")
	expectRowsContainAll(t, dirtyRows, "Ctrl+S=save", "\033[0m\033[38;2;", "\033[3mCtrl+S=save")
	expectRowsNotContainAny(t, dirtyRows, "\033[1mCtrl+S=save")
}

func TestScopedRoutingProviderRuleCandidatesUseAvailableCommonDeployments(t *testing.T) {
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

func routingFieldIndex(t *testing.T, fields []cfgField, label string) int {
	t.Helper()
	for i, field := range fields {
		if field.label == label {
			return i
		}
	}
	t.Fatalf("routing field %q not found in %+v", label, fields)
	return -1
}

func sendConfigArrow(app *App, final byte) {
	stdinCh := make(chan byte, 1)
	stdinCh <- '['
	app.handleConfigByte(handleConfigByteOptions{
		ch:      '\033',
		stdinCh: stdinCh,
		readByte: func() (byte, bool) {
			return final, true
		},
	})
}
