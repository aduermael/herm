// models.go defines model definitions, catalog lookups, sorting, filtering,
// and formatting helpers for the AI provider model selection UI.
package main

import (
	"sort"
	"strings"
	"sync"

	"langdag.com/langdag"
	"langdag.com/langdag/types"
)

// Provider constants for supported AI providers.
const (
	ProviderAnthropic  = "anthropic"
	ProviderGrok       = "grok"
	ProviderOpenRouter = "openrouter"
	ProviderOpenAI     = "openai"
	ProviderGemini     = "gemini"
	ProviderOllama     = "ollama"
	ProviderApple      = "apple"
)

// supportedProviders lists providers in display order.
var supportedProviders = []string{ProviderAnthropic, ProviderGrok, ProviderOpenRouter, ProviderOpenAI, ProviderGemini, ProviderOllama, ProviderApple}

// ModelDef describes a model available for selection.
// Models are derived from the langdag model catalog at runtime.
type ModelDef struct {
	Provider               string
	OwnerProvider          string
	ID                     string
	CanonicalID            string
	Label                  string  // optional display name override (e.g. "model (offline)")
	PromptPrice            float64 // USD per million input tokens
	CompletionPrice        float64 // USD per million output tokens
	PricingStatus          types.CostStatus
	PricingCurrency        string
	PricingRatesPer1M      map[string]float64
	MissingPriceDimensions []string
	PriceLabel             string
	RouteDependentPricing  bool
	ContextWindow          int      // tokens
	SWEScore               float64  // SWE-bench Verified score (0 = no data)
	ServerTools            []string // server-side tools supported by this model (e.g. "web_search")
	NativeModelIDs         []string
	RuntimeDiscovered      bool
	Deployments            []ModelDeploymentDef
	RouteDiagnostics       []string
}

type ModelDeploymentDef struct {
	DeploymentID    string
	ProviderID      string
	APIProtocolID   string
	OfferingID      string
	NativeModelID   string
	MappingRequired bool
	ServerTools     []string
	PricingSnapshot types.PricingSnapshot
}

// modelsFromCatalog builds the model list from the langdag catalog.
// It returns one row per canonical model and keeps deployment/offering metadata
// on each row so availability, diagnostics, and cost fallback remain route
// aware.
func modelsFromCatalog(catalog *langdag.ModelCatalog) []ModelDef {
	if catalog == nil {
		return nil
	}
	compiled, err := langdag.CompileCatalogV1(catalog)
	if err != nil {
		return nil
	}

	canonicalIDs := map[string]bool{}
	for canonicalID := range compiled.OfferingsByCanonicalModel {
		canonicalIDs[canonicalID] = true
	}
	for canonicalID := range compiled.OfferingTemplatesByCanonicalModel {
		canonicalIDs[canonicalID] = true
	}
	ids := make([]string, 0, len(canonicalIDs))
	for id := range canonicalIDs {
		ids = append(ids, id)
	}
	sort.Strings(ids)

	models := make([]ModelDef, 0, len(ids))
	for _, canonicalID := range ids {
		model := compiled.ModelsByID[canonicalID]
		if model == nil {
			continue
		}
		ownerProvider := canonicalProviderID(model.ProviderID)
		if ownerProvider == "" {
			ownerProvider = ownerProviderFromCanonicalID(canonicalID)
		}

		var deployments []ModelDeploymentDef
		for _, offering := range compiled.OfferingsByCanonicalModel[canonicalID] {
			deployments = append(deployments, modelDeploymentFromOffering(offering))
		}
		for _, template := range compiled.OfferingTemplatesByCanonicalModel[canonicalID] {
			deployments = append(deployments, modelDeploymentFromTemplate(template))
		}
		if len(deployments) == 0 {
			continue
		}

		price := summarizeModelPricing(deployments)
		nativeIDs := modelNativeIDs(modelNativeIDsOptions{model: model, deployments: deployments})
		serverTools := supportedServerToolsForDeployments(deployments)
		models = append(models, ModelDef{
			Provider:               ownerProvider,
			OwnerProvider:          ownerProvider,
			ID:                     canonicalID,
			CanonicalID:            canonicalID,
			PromptPrice:            price.promptPrice,
			CompletionPrice:        price.completionPrice,
			PricingStatus:          price.status,
			PricingCurrency:        price.currency,
			PricingRatesPer1M:      price.ratesPer1M,
			MissingPriceDimensions: price.missingDimensions,
			PriceLabel:             price.label,
			RouteDependentPricing:  price.routeDependent,
			ContextWindow:          model.ContextWindow,
			ServerTools:            serverTools,
			NativeModelIDs:         nativeIDs,
			Deployments:            deployments,
		})
	}
	return models
}

func ownerProviderFromCanonicalID(canonicalID string) string {
	owner, _, ok := strings.Cut(canonicalID, "/")
	if !ok {
		return ""
	}
	return canonicalProviderID(owner)
}

func modelDeploymentFromOffering(offering *langdag.ModelOfferingV1) ModelDeploymentDef {
	if offering == nil {
		return ModelDeploymentDef{}
	}
	providerID, protocolID := offeringProviderAndProtocol(offering)
	return ModelDeploymentDef{
		DeploymentID:    offering.DeploymentID,
		ProviderID:      providerID,
		APIProtocolID:   protocolID,
		OfferingID:      offering.ID,
		NativeModelID:   offering.NativeModelID,
		MappingRequired: false,
		ServerTools:     supportedServerToolsFromCapabilities(offering.Capabilities),
		PricingSnapshot: catalogPricingSnapshot(offering.Pricing),
	}
}

func modelDeploymentFromTemplate(template *langdag.ModelOfferingTemplateV1) ModelDeploymentDef {
	if template == nil {
		return ModelDeploymentDef{}
	}
	providerID, protocolID := templateProviderAndProtocol(template)
	return ModelDeploymentDef{
		DeploymentID:    template.DeploymentID,
		ProviderID:      providerID,
		APIProtocolID:   protocolID,
		OfferingID:      template.ID,
		MappingRequired: template.MappingRequired || template.NativeModelIDSource == langdag.NativeModelIDUserConfigured || template.NativeModelIDSource == langdag.NativeModelIDCatalogOrUser,
		ServerTools:     supportedServerToolsFromCapabilities(template.Capabilities),
		PricingSnapshot: catalogPricingSnapshot(template.Pricing),
	}
}

func deploymentProviderAndProtocol(deployment *langdag.DeploymentV1) (string, string) {
	if deployment == nil {
		return "", ""
	}
	return deployment.ProviderID, deployment.APIProtocolID
}

func offeringProviderAndProtocol(offering *langdag.ModelOfferingV1) (string, string) {
	providerID, protocolID := deploymentProviderAndProtocol(offering.Deployment)
	if offering.APIProtocolID != "" {
		protocolID = offering.APIProtocolID
	} else if offering.APIProtocol != nil {
		protocolID = offering.APIProtocol.ID
	}
	return providerID, protocolID
}

func templateProviderAndProtocol(template *langdag.ModelOfferingTemplateV1) (string, string) {
	providerID, protocolID := deploymentProviderAndProtocol(template.Deployment)
	if template.APIProtocolID != "" {
		protocolID = template.APIProtocolID
	} else if template.APIProtocol != nil {
		protocolID = template.APIProtocol.ID
	}
	return providerID, protocolID
}

func supportedServerToolsFromCapabilities(capabilities langdag.CapabilitySetV1) []string {
	var tools []string
	for tool, state := range capabilities.ServerTools {
		if state == langdag.CapabilitySupported {
			tools = append(tools, tool)
		}
	}
	sort.Strings(tools)
	return tools
}

func supportedServerToolsForDeployments(deployments []ModelDeploymentDef) []string {
	seen := map[string]bool{}
	for _, deployment := range deployments {
		for _, tool := range deployment.ServerTools {
			if tool != "" {
				seen[tool] = true
			}
		}
	}
	tools := make([]string, 0, len(seen))
	for tool := range seen {
		tools = append(tools, tool)
	}
	sort.Strings(tools)
	return tools
}

// modelNativeIDsOptions is the parameter bundle for modelNativeIDs.
type modelNativeIDsOptions struct {
	model       *langdag.ModelV1
	deployments []ModelDeploymentDef
}

func modelNativeIDs(opts modelNativeIDsOptions) []string {
	seen := map[string]bool{}
	var ids []string
	add := func(id string) {
		if id == "" || seen[id] {
			return
		}
		seen[id] = true
		ids = append(ids, id)
	}
	if opts.model != nil {
		for _, alias := range opts.model.Aliases {
			add(alias)
		}
	}
	for _, deployment := range opts.deployments {
		add(deployment.NativeModelID)
	}
	return ids
}

var (
	embeddedModelIDMigrationOfferingsOnce sync.Once
	embeddedModelIDMigrationOfferings     []ModelIDMigrationOffering
)

func embeddedCatalogModelIDMigrationOfferings() []ModelIDMigrationOffering {
	embeddedModelIDMigrationOfferingsOnce.Do(func() {
		catalog, err := langdag.DefaultModelCatalog()
		if err != nil {
			return
		}
		embeddedModelIDMigrationOfferings = modelIDMigrationOfferingsFromCatalog(catalog)
	})
	return append([]ModelIDMigrationOffering(nil), embeddedModelIDMigrationOfferings...)
}

func modelIDMigrationOfferingsFromCatalog(catalog *langdag.ModelCatalog) []ModelIDMigrationOffering {
	if catalog == nil {
		return nil
	}
	var offerings []ModelIDMigrationOffering
	add := func(canonicalID, deploymentID, nativeID string) {
		if canonicalID == "" || nativeID == "" {
			return
		}
		offerings = append(offerings, ModelIDMigrationOffering{
			CanonicalModelID: canonicalID,
			DeploymentID:     deploymentID,
			NativeModelID:    nativeID,
		})
	}
	for _, offering := range catalog.Offerings {
		add(offering.CanonicalModelID, offering.DeploymentID, offering.NativeModelID)
	}
	for canonicalID, model := range catalog.Models {
		if model == nil {
			continue
		}
		if canonicalID == "" {
			canonicalID = model.ID
		}
		for _, alias := range model.Aliases {
			add(canonicalID, "", alias)
		}
	}
	for alias, canonicalID := range catalog.Aliases {
		add(canonicalID, "", alias)
	}
	return uniqueModelIDMigrationOfferings(offerings)
}

func modelIDMigrationOfferingsFromModels(models []ModelDef) []ModelIDMigrationOffering {
	var offerings []ModelIDMigrationOffering
	add := func(canonicalID, deploymentID, nativeID string) {
		if canonicalID == "" || nativeID == "" {
			return
		}
		offerings = append(offerings, ModelIDMigrationOffering{
			CanonicalModelID: canonicalID,
			DeploymentID:     deploymentID,
			NativeModelID:    nativeID,
		})
	}
	for _, model := range models {
		canonicalID := model.CanonicalID
		if canonicalID == "" && looksCanonicalModelID(model.ID) {
			canonicalID = model.ID
		}
		if canonicalID == "" {
			continue
		}
		if model.ID != "" && model.ID != canonicalID {
			add(canonicalID, "", model.ID)
		}
		for _, nativeID := range model.NativeModelIDs {
			add(canonicalID, "", nativeID)
		}
		for _, deployment := range model.Deployments {
			add(canonicalID, deployment.DeploymentID, deployment.NativeModelID)
			add(canonicalID, deployment.DeploymentID, deployment.OfferingID)
		}
	}
	return uniqueModelIDMigrationOfferings(offerings)
}

func uniqueModelIDMigrationOfferings(offerings []ModelIDMigrationOffering) []ModelIDMigrationOffering {
	seen := map[string]bool{}
	var unique []ModelIDMigrationOffering
	for _, offering := range offerings {
		key := offering.CanonicalModelID + "\x00" + offering.DeploymentID + "\x00" + offering.NativeModelID
		if offering.CanonicalModelID == "" || offering.NativeModelID == "" || seen[key] {
			continue
		}
		seen[key] = true
		unique = append(unique, offering)
	}
	return unique
}

func catalogPricingSnapshot(pricing langdag.PricingV1) types.PricingSnapshot {
	rates := map[string]float64{}
	for name, rate := range pricing.RatesPer1M {
		rates[name] = rate
	}
	status := catalogCostStatus(pricing.Status)
	if status == "" {
		status = types.CostStatusUnknown
	}
	if status == types.CostStatusUnknown {
		rates = nil
	}
	currency := pricing.Currency
	if currency == "" {
		currency = "USD"
	}
	return types.PricingSnapshot{
		Status:            status,
		Currency:          currency,
		EffectiveAt:       pricing.EffectiveAt,
		Source:            types.CostSourceCatalog,
		RatesPer1M:        rates,
		MissingDimensions: append([]string(nil), pricing.MissingDimensions...),
	}
}

func catalogCostStatus(status langdag.PricingStatus) types.CostStatus {
	switch status {
	case langdag.PricingKnown:
		return types.CostStatusKnown
	case langdag.PricingPartial:
		return types.CostStatusPartial
	case langdag.PricingFree:
		return types.CostStatusFree
	default:
		return types.CostStatusUnknown
	}
}

type modelPricingSummary struct {
	status            types.CostStatus
	currency          string
	ratesPer1M        map[string]float64
	missingDimensions []string
	promptPrice       float64
	completionPrice   float64
	label             string
	routeDependent    bool
}

func summarizeModelPricing(deployments []ModelDeploymentDef) modelPricingSummary {
	if len(deployments) == 0 {
		return modelPricingSummary{status: types.CostStatusUnknown, currency: "USD", label: "unknown"}
	}

	currency := ""
	unknown := false
	partial := false
	knownCount := 0
	allFree := true
	missing := map[string]bool{}
	ratesByDimension := map[string]map[float64]bool{}
	var inputMin, inputMax, outputMin, outputMax float64
	haveInputOutput := false

	addRate := func(name string, rate float64) {
		if ratesByDimension[name] == nil {
			ratesByDimension[name] = map[float64]bool{}
		}
		ratesByDimension[name][rate] = true
	}

	for _, deployment := range deployments {
		snapshot := deployment.PricingSnapshot
		if currency == "" && snapshot.Currency != "" {
			currency = snapshot.Currency
		} else if snapshot.Currency != "" && currency != "" && snapshot.Currency != currency {
			unknown = true
		}
		if snapshot.Status != types.CostStatusFree {
			allFree = false
		}
		switch snapshot.Status {
		case types.CostStatusFree, types.CostStatusKnown, types.CostStatusPartial:
			if snapshot.Status == types.CostStatusPartial {
				partial = true
			}
			for _, dimension := range snapshot.MissingDimensions {
				if dimension != "" {
					missing[dimension] = true
				}
			}
			if len(snapshot.RatesPer1M) == 0 && snapshot.Status != types.CostStatusFree {
				unknown = true
				continue
			}
			knownCount++
			for dimension, rate := range snapshot.RatesPer1M {
				addRate(dimension, rate)
			}
			inputRate := snapshot.RatesPer1M["input_tokens"]
			outputRate := snapshot.RatesPer1M["output_tokens"]
			if !haveInputOutput {
				inputMin, inputMax = inputRate, inputRate
				outputMin, outputMax = outputRate, outputRate
				haveInputOutput = true
			} else {
				if inputRate < inputMin {
					inputMin = inputRate
				}
				if inputRate > inputMax {
					inputMax = inputRate
				}
				if outputRate < outputMin {
					outputMin = outputRate
				}
				if outputRate > outputMax {
					outputMax = outputRate
				}
			}
		default:
			unknown = true
			allFree = false
			for _, dimension := range snapshot.MissingDimensions {
				if dimension != "" {
					missing[dimension] = true
				}
			}
		}
	}

	if currency == "" {
		currency = "USD"
	}
	if knownCount == 0 {
		return modelPricingSummary{
			status:            types.CostStatusUnknown,
			currency:          currency,
			missingDimensions: sortedStringSet(missing),
			label:             "unknown",
		}
	}

	routeDependent := false
	for _, values := range ratesByDimension {
		if len(values) > 1 {
			routeDependent = true
			break
		}
	}

	if allFree {
		return modelPricingSummary{
			status:          types.CostStatusFree,
			currency:        currency,
			ratesPer1M:      map[string]float64{"input_tokens": 0, "output_tokens": 0},
			promptPrice:     0,
			completionPrice: 0,
			label:           "free",
		}
	}

	status := types.CostStatusKnown
	switch {
	case unknown && knownCount == 0:
		status = types.CostStatusUnknown
	case unknown || partial:
		status = types.CostStatusPartial
	}

	rates := map[string]float64{}
	if !routeDependent {
		for dimension, values := range ratesByDimension {
			for rate := range values {
				rates[dimension] = rate
			}
		}
	}

	label := "unknown"
	switch {
	case status == types.CostStatusUnknown:
		label = "unknown"
	case status == types.CostStatusPartial:
		label = "partial"
	case routeDependent && haveInputOutput:
		label = formatPriceRangePerM(formatPriceRangePerMOptions{
			inputMin:  inputMin,
			inputMax:  inputMax,
			outputMin: outputMin,
			outputMax: outputMax,
		})
	default:
		label = formatPricePerM(formatPricePerMOptions{promptPrice: inputMin, completionPrice: outputMin})
	}

	return modelPricingSummary{
		status:            status,
		currency:          currency,
		ratesPer1M:        rates,
		missingDimensions: sortedStringSet(missing),
		promptPrice:       inputMin,
		completionPrice:   outputMin,
		label:             label,
		routeDependent:    routeDependent,
	}
}

func sortedStringSet(values map[string]bool) []string {
	if len(values) == 0 {
		return nil
	}
	out := make([]string, 0, len(values))
	for value := range values {
		out = append(out, value)
	}
	sort.Strings(out)
	return out
}
