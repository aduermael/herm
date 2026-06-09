// models_dynamic.go merges runtime model discoveries with catalog data and contains model lookup helpers.
package main

import "langdag.com/langdag"

// modelsFromCatalogPreservingDynamicOptions is the parameter bundle for modelsFromCatalogPreservingDynamic.
type modelsFromCatalogPreservingDynamicOptions struct {
	catalog *langdag.ModelCatalog
	current []ModelDef
}

func modelsFromCatalogPreservingDynamic(opts modelsFromCatalogPreservingDynamicOptions) []ModelDef {
	models := modelsFromCatalog(opts.catalog)
	dynamic := dynamicModelsForProviders(dynamicModelsForProvidersOptions{
		models: opts.current,
		providers: map[string]bool{
			ProviderOllama:     true,
			ProviderOpenRouter: true,
			ProviderApple:      true,
		},
	})
	return mergeDynamicModels(mergeDynamicModelsOptions{base: models, dynamic: dynamic})
}

type dynamicModelsForProvidersOptions struct {
	models    []ModelDef
	providers map[string]bool
}

func dynamicModelsForProviders(opts dynamicModelsForProvidersOptions) []ModelDef {
	var dynamic []ModelDef
	for _, model := range opts.models {
		if !opts.providers[model.Provider] {
			continue
		}
		dynamic = append(dynamic, model)
	}
	return dynamic
}

// mergeDynamicModelsOptions is the parameter bundle for mergeDynamicModels.
type mergeDynamicModelsOptions struct {
	base    []ModelDef
	dynamic []ModelDef
}

func mergeDynamicModels(opts mergeDynamicModelsOptions) []ModelDef {
	base := opts.base
	index := map[string]int{}
	for i, model := range base {
		index[model.ID] = i
	}
	for _, model := range opts.dynamic {
		if i, ok := index[model.ID]; ok {
			base[i] = mergeModelDefs(mergeModelDefsOptions{base: base[i], dynamic: model})
			continue
		}
		index[model.ID] = len(base)
		base = append(base, model)
	}
	return base
}

// mergeModelDefsOptions is the parameter bundle for mergeModelDefs.
type mergeModelDefsOptions struct {
	base    ModelDef
	dynamic ModelDef
}

func mergeModelDefs(opts mergeModelDefsOptions) ModelDef {
	merged := opts.base
	dynamic := opts.dynamic
	if merged.Provider == "" {
		merged.Provider = dynamic.Provider
	}
	if merged.OwnerProvider == "" {
		merged.OwnerProvider = dynamic.OwnerProvider
	}
	if merged.CanonicalID == "" {
		merged.CanonicalID = dynamic.CanonicalID
	}
	if merged.ContextWindow == 0 {
		merged.ContextWindow = dynamic.ContextWindow
	}
	merged.NativeModelIDs = appendUniqueStrings(merged.NativeModelIDs, dynamic.NativeModelIDs...)
	for _, deployment := range dynamic.Deployments {
		merged.Deployments = appendUniqueDeployment(appendUniqueDeploymentOptions{
			deployments: merged.Deployments,
			next:        deployment,
		})
	}
	merged.ServerTools = supportedServerToolsForDeployments(merged.Deployments)
	price := summarizeModelPricing(merged.Deployments)
	merged.PromptPrice = price.promptPrice
	merged.CompletionPrice = price.completionPrice
	merged.PricingStatus = price.status
	merged.PricingCurrency = price.currency
	merged.PricingRatesPer1M = price.ratesPer1M
	merged.MissingPriceDimensions = price.missingDimensions
	merged.PriceLabel = price.label
	merged.RouteDependentPricing = price.routeDependent
	return merged
}

func appendUniqueStrings(base []string, values ...string) []string {
	seen := map[string]bool{}
	for _, value := range base {
		if value != "" {
			seen[value] = true
		}
	}
	for _, value := range values {
		if value == "" || seen[value] {
			continue
		}
		seen[value] = true
		base = append(base, value)
	}
	return base
}

// appendUniqueDeploymentOptions is the parameter bundle for appendUniqueDeployment.
type appendUniqueDeploymentOptions struct {
	deployments []ModelDeploymentDef
	next        ModelDeploymentDef
}

func appendUniqueDeployment(opts appendUniqueDeploymentOptions) []ModelDeploymentDef {
	key := opts.next.DeploymentID + "\x00" + opts.next.NativeModelID + "\x00" + opts.next.OfferingID
	for i, deployment := range opts.deployments {
		existingKey := deployment.DeploymentID + "\x00" + deployment.NativeModelID + "\x00" + deployment.OfferingID
		if existingKey == key {
			opts.deployments[i] = opts.next
			return opts.deployments
		}
	}
	return append(opts.deployments, opts.next)
}

// supportsServerToolsOptions is the parameter bundle for supportsServerTools.
type supportsServerToolsOptions struct {
	provider string
	modelID  string
	models   []ModelDef
}

// supportsServerTools reports whether a model supports server-side tools
// (e.g. web search). Uses catalog metadata when available; falls back to
// provider-level heuristics for models not in the catalog (e.g. Ollama).
func supportsServerTools(opts supportsServerToolsOptions) bool {
	// Check catalog metadata first.
	if m := findModelByID(findModelByIDOptions{models: opts.models, id: opts.modelID}); m != nil {
		for _, st := range m.ServerTools {
			if st == "web_search" {
				return true
			}
		}
		// Model found in catalog but no web_search — not supported.
		return false
	}
	// Model not in catalog (e.g. Ollama local models) — no server tools.
	return false
}

// filterModelsByProvidersOptions is the parameter bundle for filterModelsByProviders.
type filterModelsByProvidersOptions struct {
	models    []ModelDef
	providers map[string]bool
}

// filterModelsByProviders returns models whose provider is in the given set.
func filterModelsByProviders(opts filterModelsByProvidersOptions) []ModelDef {
	var result []ModelDef
	for _, m := range opts.models {
		if opts.providers[m.Provider] || opts.providers[m.OwnerProvider] {
			result = append(result, m)
		}
	}
	return result
}

// findModelByIDOptions is the parameter bundle for findModelByID.
type findModelByIDOptions struct {
	models []ModelDef
	id     string
}

// findModelByID returns the model with the given ID, or nil if not found.
func findModelByID(opts findModelByIDOptions) *ModelDef {
	for i := range opts.models {
		if modelMatchesID(modelMatchesIDOptions{model: opts.models[i], id: opts.id}) {
			return &opts.models[i]
		}
	}
	return nil
}

// findModelsByIDOptions is the parameter bundle for findModelsByID.
type findModelsByIDOptions struct {
	models []ModelDef
	id     string
}

func findModelsByID(opts findModelsByIDOptions) []ModelDef {
	var matches []ModelDef
	for _, model := range opts.models {
		if modelMatchesID(modelMatchesIDOptions{model: model, id: opts.id}) {
			matches = append(matches, model)
		}
	}
	return matches
}

// modelListContainsIDOptions is the parameter bundle for modelListContainsID.
type modelListContainsIDOptions struct {
	models []ModelDef
	id     string
}

func modelListContainsID(opts modelListContainsIDOptions) bool {
	return findModelByID(findModelByIDOptions{models: opts.models, id: opts.id}) != nil
}

// modelMatchesIDOptions is the parameter bundle for modelMatchesID.
type modelMatchesIDOptions struct {
	model ModelDef
	id    string
}

func modelMatchesID(opts modelMatchesIDOptions) bool {
	if opts.id == "" {
		return false
	}
	if opts.model.ID == opts.id || opts.model.CanonicalID == opts.id {
		return true
	}
	for _, legacyID := range opts.model.NativeModelIDs {
		if legacyID == opts.id {
			return true
		}
	}
	for _, deployment := range opts.model.Deployments {
		if deployment.NativeModelID == opts.id || deployment.OfferingID == opts.id {
			return true
		}
	}
	return false
}

// modelHasDeploymentOptions is the parameter bundle for modelHasDeployment.
type modelHasDeploymentOptions struct {
	model        ModelDef
	deploymentID string
}

func modelHasDeployment(opts modelHasDeploymentOptions) bool {
	for _, deployment := range opts.model.Deployments {
		if deployment.DeploymentID == opts.deploymentID {
			return true
		}
	}
	return false
}
