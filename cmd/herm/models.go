// models.go defines model definitions, catalog lookups, sorting, filtering,
// and formatting helpers for the AI provider model selection UI.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

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
)

// supportedProviders lists providers in display order.
var supportedProviders = []string{ProviderAnthropic, ProviderGrok, ProviderOpenRouter, ProviderOpenAI, ProviderGemini, ProviderOllama}

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
		nativeIDs := modelNativeIDs(model, deployments)
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
	providerID, protocolID := deploymentProviderAndProtocol(offering.Deployment)
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
	providerID, protocolID := deploymentProviderAndProtocol(template.Deployment)
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

func modelNativeIDs(model *langdag.ModelV1, deployments []ModelDeploymentDef) []string {
	seen := map[string]bool{}
	var ids []string
	add := func(id string) {
		if id == "" || seen[id] {
			return
		}
		seen[id] = true
		ids = append(ids, id)
	}
	if model != nil {
		for _, alias := range model.Aliases {
			add(alias)
		}
	}
	for _, deployment := range deployments {
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
		label = formatPriceRangePerM(inputMin, inputMax, outputMin, outputMax)
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

func modelsFromCatalogPreservingDynamic(catalog *langdag.ModelCatalog, current []ModelDef) []ModelDef {
	models := modelsFromCatalog(catalog)
	var dynamic []ModelDef
	for _, model := range current {
		if model.Provider != ProviderOllama && model.Provider != ProviderOpenRouter {
			continue
		}
		dynamic = append(dynamic, model)
	}
	return mergeDynamicModels(models, dynamic)
}

func mergeDynamicModels(base []ModelDef, dynamic []ModelDef) []ModelDef {
	index := map[string]int{}
	for i, model := range base {
		index[model.ID] = i
	}
	for _, model := range dynamic {
		if i, ok := index[model.ID]; ok {
			base[i] = mergeModelDefs(base[i], model)
			continue
		}
		index[model.ID] = len(base)
		base = append(base, model)
	}
	return base
}

func mergeModelDefs(base, dynamic ModelDef) ModelDef {
	merged := base
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
		merged.Deployments = appendUniqueDeployment(merged.Deployments, deployment)
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

func appendUniqueDeployment(deployments []ModelDeploymentDef, next ModelDeploymentDef) []ModelDeploymentDef {
	key := next.DeploymentID + "\x00" + next.NativeModelID + "\x00" + next.OfferingID
	for i, deployment := range deployments {
		existingKey := deployment.DeploymentID + "\x00" + deployment.NativeModelID + "\x00" + deployment.OfferingID
		if existingKey == key {
			deployments[i] = next
			return deployments
		}
	}
	return append(deployments, next)
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

// fetchOllamaModels fetches available models from an Ollama instance.
// Returns nil if the Ollama server is unreachable or no baseURL is configured.
func fetchOllamaModels(baseURL string) []ModelDef {
	if baseURL == "" {
		return nil
	}

	client := &http.Client{Timeout: 5 * time.Second}
	base := strings.TrimRight(baseURL, "/")

	resp, err := client.Get(base + "/api/tags")
	if err != nil {
		return nil
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil
	}

	var tagsResp struct {
		Models []struct {
			Name string `json:"name"`
		} `json:"models"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&tagsResp); err != nil {
		return nil
	}

	type result struct {
		idx   int
		model ModelDef
	}
	ch := make(chan result, len(tagsResp.Models))
	for i, m := range tagsResp.Models {
		i, m := i, m
		go func() {
			canonicalID := ollamaCanonicalModelID(m.Name)
			ch <- result{i, ModelDef{
				Provider:        ProviderOllama,
				OwnerProvider:   ProviderOllama,
				ID:              canonicalID,
				CanonicalID:     canonicalID,
				PromptPrice:     0,
				CompletionPrice: 0,
				PricingStatus:   types.CostStatusFree,
				PricingCurrency: "USD",
				PricingRatesPer1M: map[string]float64{
					"input_tokens":  0,
					"output_tokens": 0,
				},
				PriceLabel:     "free",
				ContextWindow:  ollamaContextWindow(ollamaContextWindowOptions{client: client, baseURL: base, modelName: m.Name}),
				NativeModelIDs: []string{m.Name},
				Deployments: []ModelDeploymentDef{{
					DeploymentID:  "ollama-local",
					ProviderID:    ProviderOllama,
					APIProtocolID: "openai-chat-completions",
					OfferingID:    "ollama-local:" + m.Name,
					NativeModelID: m.Name,
					PricingSnapshot: types.PricingSnapshot{
						Status:     types.CostStatusFree,
						Currency:   "USD",
						Source:     types.CostSourceCatalog,
						RatesPer1M: map[string]float64{"input_tokens": 0, "output_tokens": 0},
					},
				}},
			}}
		}()
	}
	models := make([]ModelDef, len(tagsResp.Models))
	for range tagsResp.Models {
		r := <-ch
		models[r.idx] = r.model
	}
	return models
}

const openRouterDefaultBase = "https://openrouter.ai/api/v1"
const openRouterReferer = "https://github.com/aduermael/herm"

// fetchOpenRouterOptions is the parameter bundle for fetchOpenRouterModelsFrom.
type fetchOpenRouterOptions struct {
	apiKey  string
	baseURL string
}

// fetchOpenRouterModels fetches available models from the OpenRouter API.
// Returns nil if apiKey is empty or the request fails.
func fetchOpenRouterModels(apiKey string) []ModelDef {
	return fetchOpenRouterModelsFrom(fetchOpenRouterOptions{apiKey: apiKey, baseURL: openRouterDefaultBase})
}

// fetchOpenRouterModelsFrom fetches models using the given base URL.
func fetchOpenRouterModelsFrom(opts fetchOpenRouterOptions) []ModelDef {
	apiKey, baseURL := opts.apiKey, opts.baseURL
	if apiKey == "" {
		return nil
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	client := &http.Client{}
	req, err := http.NewRequestWithContext(ctx, "GET", baseURL+"/models", nil)
	if err != nil {
		return nil
	}
	req.Header.Set("Authorization", "Bearer "+apiKey)
	req.Header.Set("HTTP-Referer", openRouterReferer)
	req.Header.Set("X-Title", "herm")

	resp, err := client.Do(req)
	if err != nil {
		return nil
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil
	}

	var body struct {
		Data []struct {
			ID            string `json:"id"`
			Name          string `json:"name"`
			ContextLength int    `json:"context_length"`
			Pricing       struct {
				Prompt     string `json:"prompt"`
				Completion string `json:"completion"`
			} `json:"pricing"`
			TopProvider struct {
				MaxCompletionTokens int `json:"max_completion_tokens"`
			} `json:"top_provider"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return nil
	}

	models := make([]ModelDef, 0, len(body.Data))
	for _, m := range body.Data {
		var promptPrice, completionPrice float64
		pricingStatus := types.CostStatusKnown
		// Prices are per-token strings; convert to per-million
		if p, err := strconv.ParseFloat(m.Pricing.Prompt, 64); err == nil {
			promptPrice = p * 1_000_000
		} else {
			pricingStatus = types.CostStatusUnknown
		}
		if p, err := strconv.ParseFloat(m.Pricing.Completion, 64); err == nil {
			completionPrice = p * 1_000_000
		} else {
			pricingStatus = types.CostStatusUnknown
		}
		if strings.Contains(m.ID, ":free") || (pricingStatus == types.CostStatusKnown && promptPrice == 0 && completionPrice == 0) {
			pricingStatus = types.CostStatusFree
		}
		ownerProvider := ownerProviderFromCanonicalID(m.ID)
		if ownerProvider == "" {
			ownerProvider = ProviderOpenRouter
		}
		priceLabel := formatPricePerM(formatPricePerMOptions{promptPrice: promptPrice, completionPrice: completionPrice})
		if pricingStatus == types.CostStatusFree {
			priceLabel = "free"
		} else if pricingStatus == types.CostStatusUnknown {
			priceLabel = "unknown"
		}
		rates := map[string]float64{"input_tokens": promptPrice, "output_tokens": completionPrice}
		if pricingStatus == types.CostStatusUnknown {
			rates = nil
		}
		models = append(models, ModelDef{
			Provider:          ProviderOpenRouter,
			OwnerProvider:     ownerProvider,
			ID:                m.ID,
			CanonicalID:       m.ID,
			PromptPrice:       promptPrice,
			CompletionPrice:   completionPrice,
			PricingStatus:     pricingStatus,
			PricingCurrency:   "USD",
			PricingRatesPer1M: rates,
			PriceLabel:        priceLabel,
			ContextWindow:     m.ContextLength,
			NativeModelIDs:    []string{m.ID},
			Deployments: []ModelDeploymentDef{{
				DeploymentID:  "openrouter",
				ProviderID:    ProviderOpenRouter,
				APIProtocolID: "openai-chat-completions",
				OfferingID:    "openrouter:" + m.ID,
				NativeModelID: m.ID,
				PricingSnapshot: types.PricingSnapshot{
					Status:     pricingStatus,
					Currency:   "USD",
					Source:     types.CostSourceCatalog,
					RatesPer1M: rates,
				},
			}},
		})
	}
	return models
}

func ollamaCanonicalModelID(modelID string) string {
	if modelID == "" || strings.HasPrefix(modelID, ProviderOllama+"/") {
		return modelID
	}
	return ProviderOllama + "/" + modelID
}

// ollamaContextWindowOptions is the parameter bundle for ollamaContextWindow.
type ollamaContextWindowOptions struct {
	client    *http.Client
	baseURL   string
	modelName string
}

// ollamaContextWindow queries /api/show for the model's actual context length.
// Returns 0 if the server doesn't provide it.
func ollamaContextWindow(opts ollamaContextWindowOptions) int {
	client, baseURL, modelName := opts.client, opts.baseURL, opts.modelName
	body, _ := json.Marshal(map[string]string{"model": modelName})
	resp, err := client.Post(baseURL+"/api/show", "application/json", bytes.NewReader(body))
	if err != nil || resp.StatusCode != http.StatusOK {
		return 0
	}
	defer resp.Body.Close()

	// model_info contains keys like "llama.context_length", "gemma3.context_length", etc.
	var showResp struct {
		ModelInfo map[string]json.RawMessage `json:"model_info"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&showResp); err != nil {
		return 0
	}
	for key, val := range showResp.ModelInfo {
		if strings.HasSuffix(key, ".context_length") {
			var n int
			if err := json.Unmarshal(val, &n); err == nil && n > 0 {
				return n
			}
		}
	}
	return 0
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
		if modelMatchesID(opts.models[i], opts.id) {
			return &opts.models[i]
		}
	}
	return nil
}

func findModelsByID(models []ModelDef, id string) []ModelDef {
	var matches []ModelDef
	for _, model := range models {
		if modelMatchesID(model, id) {
			matches = append(matches, model)
		}
	}
	return matches
}

func modelListContainsID(models []ModelDef, id string) bool {
	return findModelByID(findModelByIDOptions{models: models, id: id}) != nil
}

func modelMatchesID(model ModelDef, id string) bool {
	if id == "" {
		return false
	}
	if model.ID == id || model.CanonicalID == id {
		return true
	}
	for _, legacyID := range model.NativeModelIDs {
		if legacyID == id {
			return true
		}
	}
	for _, deployment := range model.Deployments {
		if deployment.NativeModelID == id || deployment.OfferingID == id {
			return true
		}
	}
	return false
}

func modelHasDeployment(model ModelDef, deploymentID string) bool {
	for _, deployment := range model.Deployments {
		if deployment.DeploymentID == deploymentID {
			return true
		}
	}
	return false
}

// sortModelsByColOptions is the parameter bundle for sortModelsByCol.
type sortModelsByColOptions struct {
	models []ModelDef
	col    int
	asc    bool
}

// sortModelsByCol sorts models in place by the given column.
// col: 0=Model(ID), 1=Provider, 2=Price(prompt), 3=ContextWindow.
func sortModelsByCol(opts sortModelsByColOptions) {
	models, col, asc := opts.models, opts.col, opts.asc
	sort.SliceStable(models, func(i, j int) bool {
		var less bool
		switch col {
		case 0:
			less = strings.ToLower(models[i].ID) < strings.ToLower(models[j].ID)
		case 1:
			less = strings.ToLower(modelDisplayProvider(models[i])) < strings.ToLower(modelDisplayProvider(models[j]))
		case 2:
			less = models[i].PromptPrice < models[j].PromptPrice
		case 3:
			less = models[i].ContextWindow < models[j].ContextWindow
		default:
			less = strings.ToLower(models[i].ID) < strings.ToLower(models[j].ID)
		}
		if !asc {
			return !less
		}
		return less
	})
}

// sortColNames maps column indices to config-friendly names.
var sortColNames = [4]string{"name", "provider", "price", "context"}

// sortColFromName returns the column index for a name, defaulting to 0.
func sortColFromName(name string) int {
	for i, n := range sortColNames {
		if n == name {
			return i
		}
	}
	return 0
}

// sortAscFromMap converts a config map (column name → ascending) to a [4]bool array.
// Missing columns default to ascending (true).
func sortAscFromMap(m map[string]bool) [4]bool {
	var result [4]bool
	for i, name := range sortColNames {
		if asc, ok := m[name]; ok {
			result[i] = asc
		} else {
			result[i] = true
		}
	}
	return result
}

// sortAscToMap converts a [4]bool array to a config map (column name → ascending).
func sortAscToMap(arr [4]bool) map[string]bool {
	m := make(map[string]bool, 4)
	for i, name := range sortColNames {
		m[name] = arr[i]
	}
	return m
}

// formatPrice formats a per-million-token price as "$X.XX".
func formatPrice(price float64) string {
	return fmt.Sprintf("$%.2f", price)
}

// formatPriceCompact formats a price dropping unnecessary trailing zeros.
// 5.0 → "$5", 0.15 → "$0.15", 0.80 → "$0.80", 15.0 → "$15".
func formatPriceCompact(price float64) string {
	if price == float64(int(price)) {
		return fmt.Sprintf("$%d", int(price))
	}
	return fmt.Sprintf("$%.2f", price)
}

// formatPricePerMOptions is the parameter bundle for formatPricePerM.
type formatPricePerMOptions struct {
	promptPrice     float64
	completionPrice float64
}

// formatPricePerM formats input/output prices per million tokens as "$X/$Y/M".
func formatPricePerM(opts formatPricePerMOptions) string {
	return formatPriceCompact(opts.promptPrice) + "/" + formatPriceCompact(opts.completionPrice) + "/M"
}

func formatPriceRangePerM(inputMin, inputMax, outputMin, outputMax float64) string {
	return formatPriceCompact(inputMin) + "-" + formatPriceCompact(inputMax) + "/" + formatPriceCompact(outputMin) + "-" + formatPriceCompact(outputMax) + "/M"
}

func formatModelPrice(m ModelDef) string {
	if m.PriceLabel != "" {
		return m.PriceLabel
	}
	switch m.PricingStatus {
	case types.CostStatusFree:
		return "free"
	case types.CostStatusUnknown:
		return "unknown"
	case types.CostStatusPartial:
		return "partial"
	default:
		return formatPricePerM(formatPricePerMOptions{promptPrice: m.PromptPrice, completionPrice: m.CompletionPrice})
	}
}

func modelDisplayProvider(m ModelDef) string {
	if m.OwnerProvider != "" {
		return m.OwnerProvider
	}
	return m.Provider
}

// formatContextWindow formats a token count for display.
// Examples: 128000 → "128k", 200000 → "200k", 1048576 → "1.0m".
func formatContextWindow(tokens int) string {
	if tokens >= 1000000 {
		v := float64(tokens) / 1000000.0
		if v == float64(int(v)) {
			return fmt.Sprintf("%dm", int(v))
		}
		return fmt.Sprintf("%.1fm", v)
	}
	return fmt.Sprintf("%dk", tokens/1000)
}

// formatModelMenuLinesOptions is the parameter bundle for formatModelMenuLines.
type formatModelMenuLinesOptions struct {
	models   []ModelDef
	activeID string
	sortCol  int
	sortAsc  bool
}

// formatModelMenuLines formats models as aligned multi-column menu lines.
// Columns: Model (ID), Provider, Price (prompt), Context Window.
// Returns a header string and the data lines.
// The active model is marked with ● at the end.
// sortCol (0-3) determines which column header is highlighted.
func formatModelMenuLines(opts formatModelMenuLinesOptions) (string, []string) {
	models, activeID, sortCol, sortAsc := opts.models, opts.activeID, opts.sortCol, opts.sortAsc
	// Column headers
	headers := [4]string{"Model", "Provider", "Price", "Context"}

	// Compute column widths (at least as wide as headers)
	maxName := visibleWidth(headers[0])
	maxProv := visibleWidth(headers[1])
	maxPrice := visibleWidth(headers[2])
	maxCtx := visibleWidth(headers[3])

	type entry struct {
		name, prov, price, ctx string
		active                 bool
	}
	entries := make([]entry, len(models))
	for i, m := range models {
		displayName := m.ID
		if m.Label != "" {
			displayName = m.Label
		}
		e := entry{
			name:   displayName,
			prov:   modelDisplayProvider(m),
			price:  formatModelPrice(m),
			ctx:    formatContextWindow(m.ContextWindow),
			active: modelMatchesID(m, activeID),
		}
		if visibleWidth(e.name) > maxName {
			maxName = visibleWidth(e.name)
		}
		if len(e.prov) > maxProv {
			maxProv = len(e.prov)
		}
		if len(e.price) > maxPrice {
			maxPrice = len(e.price)
		}
		if len(e.ctx) > maxCtx {
			maxCtx = len(e.ctx)
		}
		entries[i] = e
	}

	// Build header with sort indicator on active column
	// ▼ = list reads downward (A→Z / low→high), ▲ = list reads upward (Z→A / high→low)
	arrow := "▼"
	if !sortAsc {
		arrow = "▲"
	}
	hdrParts := make([]string, 4)
	widths := [4]int{maxName, maxProv, maxPrice, maxCtx}
	rightAlign := [4]bool{false, false, true, true}
	for j, h := range headers {
		label := h
		if j == sortCol {
			label = h + arrow
		}
		pad := widths[j] - visibleWidth(label)
		if pad < 0 {
			pad = 0
		}
		if rightAlign[j] {
			hdrParts[j] = strings.Repeat(" ", pad) + label
		} else {
			hdrParts[j] = label + strings.Repeat(" ", pad)
		}
	}
	header := hdrParts[0] + "  " + hdrParts[1] + "  " + hdrParts[2] + "  " + hdrParts[3]

	lines := make([]string, len(entries))
	for i, e := range entries {
		marker := " "
		if e.active {
			marker = "●"
		}
		// Pad name manually to account for invisible ANSI escape bytes.
		namePad := maxName - visibleWidth(e.name)
		if namePad < 0 {
			namePad = 0
		}
		// ● is 3 bytes but 1 visible char; adjust ctx width so right-align stays correct.
		ctxWidth := maxCtx
		if e.active {
			ctxWidth -= 2 // compensate for 2 extra bytes in ●
		}
		lines[i] = fmt.Sprintf("%s%s  %-*s  %*s  %*s %s",
			e.name,
			strings.Repeat(" ", namePad),
			maxProv, e.prov,
			maxPrice, e.price,
			ctxWidth, e.ctx,
			marker)
	}
	return header, lines
}

// catalogCachePath returns the path to the langdag model catalog cache file.
func catalogCachePath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		home = "."
	}
	return filepath.Join(home, ".herm", "model_catalog.json")
}

// computeCostOptions is the parameter bundle for computeCost.
type computeCostOptions struct {
	models  []ModelDef
	modelID string
	usage   types.Usage
}

// computeCost calculates the USD cost for a single LLM call based on token
// usage and model pricing. Prices are per million tokens. For Anthropic models,
// cache read tokens are charged at 10% of the input price.
// Returns 0 if the model is not found.
func computeCost(opts computeCostOptions) float64 {
	return computeCostResult(opts).Total
}

func computeCostResult(opts computeCostOptions) types.CostResult {
	matches := findModelsByID(opts.models, opts.modelID)
	if len(matches) == 0 {
		return types.CostResult{
			Status:            types.CostStatusUnknown,
			Source:            types.CostSourceHistorical,
			MissingDimensions: []string{"model:" + opts.modelID},
		}
	}
	if len(matches) > 1 && !sameLegacyPricing(matches) {
		return types.CostResult{
			Status:            types.CostStatusUnknown,
			Source:            types.CostSourceHistorical,
			MissingDimensions: []string{"ambiguous_model_id:" + opts.modelID},
		}
	}
	m := matches[0]
	usage := opts.usage
	snapshot := pricingSnapshotForModel(m)
	if snapshot.Status == "" {
		snapshot.Status = inferCatalogPricingStatus(m.PromptPrice, m.CompletionPrice, m.Provider, m.ID)
	}
	result := types.ComputeCostFromPricingSnapshot(snapshot, types.NormalizedUsageFromUsage(usage))
	if result.Source == "" {
		result.Source = types.CostSourceHistorical
	}
	return result
}

func sameLegacyPricing(matches []ModelDef) bool {
	if len(matches) < 2 {
		return true
	}
	first := comparablePricingSnapshotForModel(matches[0])
	for _, match := range matches[1:] {
		next := comparablePricingSnapshotForModel(match)
		if !reflect.DeepEqual(first, next) {
			return false
		}
	}
	return true
}

func comparablePricingSnapshotForModel(m ModelDef) types.PricingSnapshot {
	snapshot := pricingSnapshotForModel(m)
	if len(snapshot.RatesPer1M) == 0 {
		snapshot.RatesPer1M = nil
	}
	if len(snapshot.MissingDimensions) == 0 {
		snapshot.MissingDimensions = nil
	} else {
		sort.Strings(snapshot.MissingDimensions)
	}
	return snapshot
}

func pricingSnapshotForModel(m ModelDef) types.PricingSnapshot {
	if m.RouteDependentPricing {
		return types.PricingSnapshot{
			Status:            types.CostStatusUnknown,
			Currency:          defaultPricingCurrency(m.PricingCurrency),
			Source:            types.CostSourceCatalog,
			MissingDimensions: []string{"route_dependent_pricing:" + m.ID},
		}
	}
	rates := map[string]float64{}
	for k, v := range m.PricingRatesPer1M {
		rates[k] = v
	}
	if len(rates) == 0 {
		rates["input_tokens"] = m.PromptPrice
		rates["output_tokens"] = m.CompletionPrice
		if m.Provider == ProviderAnthropic && m.PromptPrice > 0 {
			rates["cache_read_input_tokens"] = m.PromptPrice * 0.1
		}
	}
	status := m.PricingStatus
	if status == "" {
		status = inferCatalogPricingStatus(m.PromptPrice, m.CompletionPrice, m.Provider, m.ID)
	}
	if status == types.CostStatusUnknown {
		rates = nil
	}
	currency := defaultPricingCurrency(m.PricingCurrency)
	source := types.CostSourceHistorical
	if len(m.Deployments) > 0 {
		source = types.CostSourceCatalog
	}
	return types.PricingSnapshot{
		Status:            status,
		Currency:          currency,
		Source:            source,
		RatesPer1M:        rates,
		MissingDimensions: append([]string(nil), m.MissingPriceDimensions...),
	}
}

func defaultPricingCurrency(currency string) string {
	if currency == "" {
		return "USD"
	}
	return currency
}

func inferCatalogPricingStatus(inputPrice, outputPrice float64, provider, modelID string) types.CostStatus {
	if strings.Contains(modelID, ":free") || provider == ProviderOllama {
		return types.CostStatusFree
	}
	if inputPrice == 0 && outputPrice == 0 {
		return types.CostStatusUnknown
	}
	return types.CostStatusKnown
}

// formatCost formats a USD cost for display with enough precision to show
// at least one significant digit. Very small amounts get more decimal places.
func formatCost(cost float64) string {
	switch {
	case cost >= 0.01:
		return fmt.Sprintf("$%.2f", cost)
	case cost >= 0.001:
		return fmt.Sprintf("$%.4f", cost)
	case cost >= 0.0001:
		return fmt.Sprintf("$%.5f", cost)
	default:
		return fmt.Sprintf("$%.6f", cost)
	}
}

func formatCostResult(result types.CostResult) string {
	switch result.Status {
	case types.CostStatusFree:
		return "free"
	case types.CostStatusUnknown:
		return "cost unknown"
	case types.CostStatusPartial:
		return "partial " + formatCost(result.Total)
	default:
		return formatCost(result.Total)
	}
}

// formatTokenCount formats a token count for compact display.
// Examples: 1234 → "1,234", 150000 → "150k", 1500000 → "1.5m".
func formatTokenCount(tokens int) string {
	switch {
	case tokens >= 1_000_000:
		v := float64(tokens) / 1_000_000
		if v == float64(int(v)) {
			return fmt.Sprintf("%dm", int(v))
		}
		return fmt.Sprintf("%.1fm", v)
	case tokens >= 10_000:
		return fmt.Sprintf("%dk", tokens/1000)
	default:
		return fmt.Sprintf("%d", tokens)
	}
}

// formatBytes formats a byte count for compact display.
// Examples: 500 → "500B", 15360 → "15KB", 1572864 → "1.5MB".
func formatBytes(bytes int) string {
	switch {
	case bytes >= 1_000_000:
		return fmt.Sprintf("%.1fMB", float64(bytes)/1_000_000)
	case bytes >= 1_000:
		return fmt.Sprintf("%dKB", bytes/1000)
	default:
		return fmt.Sprintf("%dB", bytes)
	}
}

// SWE-bench leaderboard types

const sweBenchURL = "https://raw.githubusercontent.com/SWE-bench/swe-bench.github.io/master/data/leaderboards.json"

type sweBenchResponse struct {
	Leaderboards []sweBenchLeaderboard `json:"leaderboards"`
}

type sweBenchLeaderboard struct {
	Name    string           `json:"name"`
	Results []sweBenchResult `json:"results"`
}

type sweBenchResult struct {
	Name     string   `json:"name"`
	Resolved float64  `json:"resolved"`
	Tags     []string `json:"tags"`
}

// parseSWEScores extracts the highest SWE-bench Verified score per model tag
// from leaderboard results. Returns a map from model tag identifier (e.g.
// "claude-opus-4-5-20251101") to the best resolved score.
func parseSWEScores(resp sweBenchResponse) map[string]float64 {
	scores := make(map[string]float64)
	for _, lb := range resp.Leaderboards {
		if lb.Name != "Verified" {
			continue
		}
		for _, r := range lb.Results {
			var modelTags []string
			for _, tag := range r.Tags {
				if strings.HasPrefix(tag, "Model: ") {
					modelTags = append(modelTags, strings.TrimPrefix(tag, "Model: "))
				}
			}
			// Skip entries with multiple model tags (multi-model systems)
			if len(modelTags) != 1 {
				continue
			}
			tag := modelTags[0]
			if r.Resolved > scores[tag] {
				scores[tag] = r.Resolved
			}
		}
		break // only process "Verified"
	}
	return scores
}

// matchSWEScoresOptions is the parameter bundle for matchSWEScores.
type matchSWEScoresOptions struct {
	models []ModelDef
	scores map[string]float64
}

// matchSWEScores enriches models with SWE-bench scores by fuzzy-matching
// model IDs against SWE-bench model tags.
func matchSWEScores(opts matchSWEScoresOptions) {
	models, scores := opts.models, opts.scores
	for i := range models {
		id := models[i].ID
		// Try exact match first, then check if either contains the other
		for tag, score := range scores {
			if tag == id || strings.Contains(tag, id) || strings.Contains(id, tag) {
				if score > models[i].SWEScore {
					models[i].SWEScore = score
				}
			}
		}
	}
}

// fetchSWEScores fetches the SWE-bench Verified leaderboard and returns
// a map of model tag identifiers to their best scores.
func fetchSWEScores() (map[string]float64, error) {
	client := &http.Client{Timeout: 15 * time.Second}
	resp, err := client.Get(sweBenchURL)
	if err != nil {
		return nil, fmt.Errorf("fetching SWE-bench scores: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("SWE-bench API returned status %d", resp.StatusCode)
	}

	var body sweBenchResponse
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return nil, fmt.Errorf("decoding SWE-bench response: %w", err)
	}

	return parseSWEScores(body), nil
}
