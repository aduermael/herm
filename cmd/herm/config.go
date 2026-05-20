// config.go defines core configuration fields and runtime deployment helpers.
package main

import (
	"fmt"
	"os"
	"strings"
)

const configDir = ".herm"
const configFile = "config.json"

type Config struct {
	ConfigVersion         int                         `json:"config_version,omitempty"`
	PasteCollapseMinChars int                         `json:"paste_collapse_min_chars"`
	RequestCacheDir       string                      `json:"-"`
	AnthropicAPIKey       string                      `json:"anthropic_api_key,omitempty"`
	GrokAPIKey            string                      `json:"grok_api_key,omitempty"`
	OpenRouterAPIKey      string                      `json:"openrouter_api_key,omitempty"`
	OpenAIAPIKey          string                      `json:"openai_api_key,omitempty"`
	GeminiAPIKey          string                      `json:"gemini_api_key,omitempty"`
	OllamaBaseURL         string                      `json:"ollama_base_url,omitempty"` // e.g., "http://localhost:11434"
	Deployments           map[string]DeploymentConfig `json:"deployments,omitempty"`
	Routing               *RoutingPolicy              `json:"routing,omitempty"`
	ActiveModel           string                      `json:"active_model,omitempty"`
	ExplorationModel      string                      `json:"exploration_model,omitempty"` // model for sub-agents; falls back to ActiveModel
	ModelSortCol          string                      `json:"model_sort_col,omitempty"`    // "name","provider","price","context"
	ModelSortDirs         map[string]bool             `json:"model_sort_dirs,omitempty"`   // column name → ascending (per-column)
	SubAgentMaxTurns      int                         `json:"sub_agent_max_turns,omitempty"`
	ExploreMaxTurns       int                         `json:"explore_max_turns,omitempty"`
	GeneralMaxTurns       int                         `json:"general_max_turns,omitempty"`
	MaxToolIterations     int                         `json:"max_tool_iterations,omitempty"` // main agent tool-call loop cap; 0 = default (200)
	MaxAgentDepth         int                         `json:"max_agent_depth,omitempty"`     // max sub-agent nesting depth; 0 = default (1)
	Personality           string                      `json:"personality,omitempty"`         // optional agent personality/tone
	HistoryMaxEntries     int                         `json:"history_max_entries,omitempty"`
	GitCoAuthor           *bool                       `json:"git_co_author,omitempty"` // nil (default) or explicit true/false
	DebugMode             bool                        `json:"debug_mode,omitempty"`
	Thinking              *bool                       `json:"thinking,omitempty"` // nil/false = disabled (default), true = enable extended thinking
}

func (c Config) effectiveGitCoAuthor() bool {
	if c.GitCoAuthor == nil {
		return true
	}
	return *c.GitCoAuthor
}

func (c Config) effectiveThinking() bool {
	if c.Thinking == nil {
		return false
	}
	return *c.Thinking
}

func (c Config) effectiveMaxHistory() int {
	if c.HistoryMaxEntries > 0 {
		return c.HistoryMaxEntries
	}
	return 100
}

// configuredProviders returns route/provider names that have enough local
// deployment configuration to be usable.
func (c Config) configuredProviders() map[string]bool {
	providers := make(map[string]bool)
	for deploymentID := range c.configuredDeploymentIDs() {
		if provider := hermProviderForDeployment(deploymentID); provider != "" {
			providers[provider] = true
		}
	}
	return providers
}

// defaultLangdagProvider returns the provider that newLangdagClient will use.
func (c Config) defaultLangdagProvider() string {
	providers := c.configuredProviders()
	for _, provider := range []string{ProviderAnthropic, ProviderOpenAI, ProviderGrok, ProviderOpenRouter, ProviderGemini, ProviderOllama} {
		if providers[provider] {
			return provider
		}
	}
	return ""
}

// availableModels returns canonical models with at least one locally configured
// deployment route. Legacy ModelDef values without deployment metadata still
// fall back to provider-key filtering for compatibility.
func (c Config) availableModels(models []ModelDef) []ModelDef {
	configuredDeployments := c.configuredDeploymentIDs()
	deploymentConfigs := c.deploymentConfigs()
	providers := c.configuredProviders()
	var available []ModelDef
	for _, model := range models {
		if len(model.Deployments) == 0 {
			if providers[model.Provider] || providers[model.OwnerProvider] {
				available = append(available, model)
			}
			continue
		}
		filtered := model
		filtered.Deployments = nil
		filtered.RouteDiagnostics = nil
		for _, deployment := range model.Deployments {
			if !configuredDeployments[deployment.DeploymentID] {
				continue
			}
			if deployment.MappingRequired && deploymentConfigs[deployment.DeploymentID].ModelMappings[model.ID] == "" {
				filtered.RouteDiagnostics = append(filtered.RouteDiagnostics, fmt.Sprintf("%s missing model_mappings[%s]", deployment.DeploymentID, model.ID))
				continue
			}
			filtered.Deployments = append(filtered.Deployments, deployment)
		}
		if len(filtered.Deployments) == 0 {
			continue
		}
		if c.Routing != nil && !routingPolicyIsEmpty(c.Routing) {
			routed, diagnostics, ok := routeAwareDeploymentsForModel(routeAwareDeploymentsForModelOptions{policy: *c.Routing, model: filtered, configuredDeployments: configuredDeployments})
			filtered.RouteDiagnostics = append(filtered.RouteDiagnostics, diagnostics...)
			if !ok {
				continue
			}
			filtered.Deployments = routed
		}
		price := summarizeModelPricing(filtered.Deployments)
		filtered.PromptPrice = price.promptPrice
		filtered.CompletionPrice = price.completionPrice
		filtered.PricingStatus = price.status
		filtered.PricingCurrency = price.currency
		filtered.PricingRatesPer1M = price.ratesPer1M
		filtered.MissingPriceDimensions = price.missingDimensions
		filtered.PriceLabel = price.label
		filtered.RouteDependentPricing = price.routeDependent
		filtered.ServerTools = supportedServerToolsForDeployments(filtered.Deployments)
		available = append(available, filtered)
	}
	return available
}

type routeAwareDeploymentsForModelOptions struct {
	policy                RoutingPolicy
	model                 ModelDef
	configuredDeployments map[string]bool
}

func routeAwareDeploymentsForModel(opts routeAwareDeploymentsForModelOptions) ([]ModelDeploymentDef, []string, bool) {
	policy, model, configuredDeployments := opts.policy, opts.model, opts.configuredDeployments
	providerID := model.OwnerProvider
	if providerID == "" {
		providerID = model.Provider
	}
	stages, source, ok := policy.routeFor(routeForOptions{
		canonicalModelID: model.ID,
		providerID:       providerID,
	})
	if !ok {
		return model.Deployments, nil, true
	}
	var diagnostics []string
	var routed []ModelDeploymentDef
	seen := map[string]bool{}
	for _, stage := range stages {
		for _, choice := range stage.Deployments {
			if choice.DeploymentID == "" || choice.Weight <= 0 {
				continue
			}
			if !configuredDeployments[choice.DeploymentID] {
				diagnostics = append(diagnostics, fmt.Sprintf("%s route uses unavailable deployment %s", source, choice.DeploymentID))
				continue
			}
			matched := false
			for _, deployment := range model.Deployments {
				if deployment.DeploymentID != choice.DeploymentID {
					continue
				}
				matched = true
				key := deployment.DeploymentID + "\x00" + deployment.NativeModelID + "\x00" + deployment.OfferingID
				if !seen[key] {
					seen[key] = true
					routed = append(routed, deployment)
				}
			}
			if !matched {
				diagnostics = append(diagnostics, fmt.Sprintf("%s route deployment %s cannot serve %s", source, choice.DeploymentID, model.ID))
			}
		}
	}
	if len(routed) == 0 {
		diagnostics = append(diagnostics, fmt.Sprintf("%s route has no eligible deployment for %s", source, model.ID))
		return nil, diagnostics, false
	}
	return routed, diagnostics, true
}

func routingPolicyIsEmpty(policy *RoutingPolicy) bool {
	return policy == nil || policy.Default == nil && len(policy.Providers) == 0 && len(policy.Models) == 0
}

type configModelsOptions struct {
	cfg    Config
	models []ModelDef
}

func routingValidationIndexForConfigModels(opts configModelsOptions) RoutingValidationIndex {
	cfg, models := opts.cfg, opts.models
	configuredDeployments := cfg.configuredDeploymentIDs()
	deploymentConfigs := cfg.deploymentConfigs()
	eligibleByModel := map[string]map[string]bool{}
	missingMappingsByModel := map[string]map[string]bool{}
	knownProviders := knownCanonicalProviderIDs()
	for _, model := range models {
		if model.OwnerProvider != "" {
			knownProviders[canonicalProviderID(model.OwnerProvider)] = true
		}
		if model.Provider != "" {
			knownProviders[canonicalProviderID(model.Provider)] = true
		}
		if model.ID == "" {
			continue
		}
		if eligibleByModel[model.ID] == nil {
			eligibleByModel[model.ID] = map[string]bool{}
		}
		for _, deployment := range model.Deployments {
			if !configuredDeployments[deployment.DeploymentID] {
				continue
			}
			if deployment.MappingRequired && deploymentConfigs[deployment.DeploymentID].ModelMappings[model.ID] == "" {
				if missingMappingsByModel[model.ID] == nil {
					missingMappingsByModel[model.ID] = map[string]bool{}
				}
				missingMappingsByModel[model.ID][deployment.DeploymentID] = true
				continue
			}
			eligibleByModel[model.ID][deployment.DeploymentID] = true
		}
	}
	return RoutingValidationIndex{
		KnownProviders:             knownProviders,
		KnownDeployments:           knownDeploymentIDs(),
		AvailableDeployments:       configuredDeployments,
		EligibleDeploymentsByModel: eligibleByModel,
		MissingMappingsByModel:     missingMappingsByModel,
	}
}

func routingDiagnosticsForConfigModels(opts configModelsOptions) []RoutingDiagnostic {
	cfg, models := opts.cfg, opts.models
	if cfg.Routing == nil {
		return nil
	}
	index := routingValidationIndexForConfigModels(configModelsOptions{cfg: cfg, models: models})
	diagnostics := cfg.Routing.validate(index)
	for _, model := range models {
		if model.ID == "" {
			continue
		}
		providerID := model.OwnerProvider
		if providerID == "" {
			providerID = model.Provider
		}
		stages, source, ok := cfg.Routing.routeFor(routeForOptions{
			canonicalModelID: model.ID,
			providerID:       providerID,
		})
		if !ok {
			continue
		}
		if source == RouteSourceModel {
			continue
		}
		path := fmt.Sprintf("routing.effective.%s.%s", source, model.ID)
		diagnostics = append(diagnostics, validateRoutingStages(validateRoutingStagesOptions{
			path:             path,
			canonicalModelID: model.ID,
			stages:           stages,
			index:            index,
		})...)
	}
	return uniqueRoutingDiagnostics(diagnostics)
}

func uniqueRoutingDiagnostics(diagnostics []RoutingDiagnostic) []RoutingDiagnostic {
	if len(diagnostics) == 0 {
		return nil
	}
	sortRoutingDiagnostics(diagnostics)
	seen := map[string]bool{}
	unique := make([]RoutingDiagnostic, 0, len(diagnostics))
	for _, diagnostic := range diagnostics {
		key := diagnostic.Path + "\x00" + diagnostic.Code + "\x00" + diagnostic.Message
		if seen[key] {
			continue
		}
		seen[key] = true
		unique = append(unique, diagnostic)
	}
	return unique
}

func (c Config) deploymentConfigs() map[string]DeploymentConfig {
	out := map[string]DeploymentConfig{}
	for deploymentID := range knownDeploymentIDs() {
		out[deploymentID] = DeploymentConfig{}
	}
	for id, deployment := range c.Deployments {
		out[id] = cloneDeploymentConfig(deployment)
	}
	mergeDeploymentConfig := func(id string, deployment DeploymentConfig) {
		current := out[id]
		mergeDeploymentConfigFields(mergeDeploymentConfigFieldsOptions{
			current:  &current,
			incoming: deployment,
		})
		out[id] = current
	}
	if c.AnthropicAPIKey != "" {
		mergeDeploymentConfig("anthropic-direct", DeploymentConfig{APIKey: c.AnthropicAPIKey})
	}
	if c.OpenAIAPIKey != "" {
		mergeDeploymentConfig("openai-direct", DeploymentConfig{APIKey: c.OpenAIAPIKey})
	}
	if c.GrokAPIKey != "" {
		mergeDeploymentConfig("grok-direct", DeploymentConfig{APIKey: c.GrokAPIKey})
	}
	if c.OpenRouterAPIKey != "" {
		mergeDeploymentConfig("openrouter", DeploymentConfig{APIKey: c.OpenRouterAPIKey})
	}
	if c.GeminiAPIKey != "" {
		mergeDeploymentConfig("gemini-direct", DeploymentConfig{APIKey: c.GeminiAPIKey})
	}
	if c.OllamaBaseURL != "" {
		mergeDeploymentConfig("ollama-local", DeploymentConfig{BaseURL: c.OllamaBaseURL})
	}
	return out
}

func cloneDeploymentConfig(deployment DeploymentConfig) DeploymentConfig {
	deployment.ModelMappings = cloneStringMap(deployment.ModelMappings)
	return deployment
}

func cloneStringMap(values map[string]string) map[string]string {
	if len(values) == 0 {
		return nil
	}
	clone := make(map[string]string, len(values))
	for key, value := range values {
		clone[key] = value
	}
	return clone
}

func (c Config) deploymentConfig(deploymentID string) DeploymentConfig {
	deployment := c.deploymentConfigs()[deploymentID]
	return deploymentWithEnvFallbacks(deploymentConfigOptions{deploymentID: deploymentID, deployment: deployment})
}

func (c Config) openRouterAPIKey() string {
	return c.deploymentConfig("openrouter").APIKey
}

func (c Config) ollamaBaseURL() string {
	return c.deploymentConfig("ollama-local").BaseURL
}

func (c Config) configuredDeploymentIDs() map[string]bool {
	configured := map[string]bool{}
	for deploymentID, deployment := range c.deploymentConfigs() {
		if deploymentHasRequiredConfig(deploymentConfigOptions{deploymentID: deploymentID, deployment: deployment}) {
			configured[deploymentID] = true
		}
	}
	return configured
}

type deploymentConfigOptions struct {
	deploymentID string
	deployment   DeploymentConfig
}

func deploymentHasRequiredConfig(opts deploymentConfigOptions) bool {
	deploymentID := opts.deploymentID
	deployment := deploymentWithEnvFallbacks(opts)
	switch deploymentID {
	case "anthropic-direct", "openai-direct", "grok-direct", "openrouter", "gemini-direct":
		return deployment.APIKey != ""
	case "openai-azure":
		return deployment.APIKey != "" && deployment.Endpoint != "" && deployment.APIVersion != ""
	case "anthropic-bedrock":
		return deployment.Region != ""
	case "anthropic-vertex", "gemini-vertex":
		return deployment.ProjectID != "" && deployment.Region != ""
	case "ollama-local":
		return deployment.BaseURL != ""
	default:
		return false
	}
}

func deploymentWithEnvFallbacks(opts deploymentConfigOptions) DeploymentConfig {
	deploymentID, deployment := opts.deploymentID, opts.deployment
	for _, fallback := range deploymentEnvFallbacks[deploymentID] {
		value := deploymentFieldValue(deploymentFieldValueOptions{deployment: deployment, field: fallback.Field})
		if value != "" {
			continue
		}
		for _, envName := range fallback.Env {
			if envValue := strings.TrimSpace(os.Getenv(envName)); envValue != "" {
				setDeploymentFieldValue(setDeploymentFieldValueOptions{deployment: &deployment, field: fallback.Field, value: envValue})
				break
			}
		}
	}
	return deployment
}

type deploymentFieldValueOptions struct {
	deployment DeploymentConfig
	field      string
}

func deploymentFieldValue(opts deploymentFieldValueOptions) string {
	deployment, field := opts.deployment, opts.field
	switch field {
	case "api_key":
		return deployment.APIKey
	case "base_url":
		return deployment.BaseURL
	case "endpoint":
		return deployment.Endpoint
	case "api_version":
		return deployment.APIVersion
	case "project_id":
		return deployment.ProjectID
	case "region":
		return deployment.Region
	default:
		return ""
	}
}

type setDeploymentFieldValueOptions struct {
	deployment *DeploymentConfig
	field      string
	value      string
}

func setDeploymentFieldValue(opts setDeploymentFieldValueOptions) {
	deployment, field, value := opts.deployment, opts.field, opts.value
	switch field {
	case "api_key":
		deployment.APIKey = value
	case "base_url":
		deployment.BaseURL = value
	case "endpoint":
		deployment.Endpoint = value
	case "api_version":
		deployment.APIVersion = value
	case "project_id":
		deployment.ProjectID = value
	case "region":
		deployment.Region = value
	}
}

func hermProviderForDeployment(deploymentID string) string {
	switch deploymentID {
	case "anthropic-direct", "anthropic-bedrock", "anthropic-vertex":
		return ProviderAnthropic
	case "openai-direct", "openai-azure":
		return ProviderOpenAI
	case "gemini-direct", "gemini-vertex":
		return ProviderGemini
	case "grok-direct":
		return ProviderGrok
	case "openrouter":
		return ProviderOpenRouter
	case "ollama-local":
		return ProviderOllama
	default:
		return ""
	}
}

type configuredProviderForModelOptions struct {
	cfg   Config
	model ModelDef
}

func configuredProviderForModel(opts configuredProviderForModelOptions) string {
	cfg, model := opts.cfg, opts.model
	available := cfg.availableModels([]ModelDef{model})
	if len(available) > 0 {
		for _, deployment := range available[0].Deployments {
			if provider := hermProviderForDeployment(deployment.DeploymentID); provider != "" {
				return provider
			}
		}
		if available[0].Provider != "" {
			return available[0].Provider
		}
		return available[0].OwnerProvider
	}
	if model.Provider != "" {
		return model.Provider
	}
	return model.OwnerProvider
}

// defaultActiveModels maps provider to the preferred default active model ID.
// These are checked against the runtime catalog — if the ID isn't present, we
// fall back to the first available model.
// Ollama is intentionally omitted: locally installed models are user-specific
// and there is no canonical default to suggest.
var defaultActiveModels = map[string]string{
	ProviderAnthropic:  "anthropic/claude-sonnet-4-6",
	ProviderOpenAI:     "openai/gpt-4.1-2025-04-14",
	ProviderGrok:       "xai/grok-4-1-fast-reasoning",
	ProviderOpenRouter: "z-ai/glm-4.5-air:free",
	ProviderGemini:     "google/gemini-2.5-pro",
}

// defaultExplorationModels maps provider to the preferred cheap/fast model
// for sub-agents and exploration tasks.
// Ollama is intentionally omitted: locally installed models are user-specific
// and there is no canonical cheap/fast default to suggest.
var defaultExplorationModels = map[string]string{
	ProviderAnthropic:  "anthropic/claude-haiku-4-5",
	ProviderOpenAI:     "openai/gpt-4.1-mini-2025-04-14",
	ProviderGrok:       "xai/grok-4-1-fast-non-reasoning",
	ProviderOpenRouter: "z-ai/glm-4.5-air:free",
	ProviderGemini:     "google/gemini-2.5-flash",
}

// preferredDefaultOptions is the parameter bundle for preferredDefault.
type preferredDefaultOptions struct {
	models   []ModelDef
	provider string
	defaults map[string]string
}

// preferredDefault looks up the default model ID for the given provider and
// returns it if it exists in the available models list. Returns "" otherwise.
func preferredDefault(opts preferredDefaultOptions) string {
	models, provider, defaults := opts.models, opts.provider, opts.defaults
	id, ok := defaults[provider]
	if !ok {
		return ""
	}
	candidates := modelIDCandidates(modelIDCandidatesOptions{modelID: id, smartDefault: id})
	for _, m := range models {
		for _, candidate := range candidates {
			if modelMatchesID(modelMatchesIDOptions{model: m, id: candidate}) {
				return m.ID
			}
		}
	}
	return ""
}

type configuredModelLookupStatus string

const (
	configuredModelUsable      configuredModelLookupStatus = "usable"
	configuredModelUnavailable configuredModelLookupStatus = "unavailable"
	configuredModelAmbiguous   configuredModelLookupStatus = "ambiguous"
	configuredModelUnknown     configuredModelLookupStatus = "unknown"
)

type configuredModelResolution struct {
	ConfiguredModelID string
	ResolvedModelID   string
	Fallback          bool
	Status            configuredModelLookupStatus
	Diagnostic        string
}

// resolveActiveModel returns a valid active model ID. If the current ActiveModel
// is invalid or its provider has no key, it falls back to the first available
// model, or empty string if no keys are configured.
func (c Config) resolveActiveModel(models []ModelDef) string {
	return c.resolveActiveModelResult(models).ResolvedModelID
}

func (c Config) resolveActiveModelResult(models []ModelDef) configuredModelResolution {
	available := c.availableModels(models)
	if c.ActiveModel != "" {
		lookup := c.lookupConfiguredModelID(lookupConfiguredModelIDOptions{modelID: c.ActiveModel, smartDefault: defaultCanonicalActiveModel, available: available, models: models})
		if lookup.Status == configuredModelUsable {
			return lookup
		}
		fallback := c.defaultActiveModel(available)
		return configuredModelResolution{
			ConfiguredModelID: c.ActiveModel,
			ResolvedModelID:   fallback,
			Fallback:          true,
			Status:            lookup.Status,
			Diagnostic:        configuredModelDiagnostic(configuredModelDiagnosticOptions{field: "active_model", configured: c.ActiveModel, fallback: fallback, status: lookup.Status}),
		}
	}
	return configuredModelResolution{ResolvedModelID: c.defaultActiveModel(available)}
}

func (c Config) defaultActiveModel(available []ModelDef) string {
	if len(available) == 0 {
		return ""
	}
	// Try provider-specific default before falling back to first available
	if id := preferredDefault(preferredDefaultOptions{models: available, provider: c.defaultLangdagProvider(), defaults: defaultActiveModels}); id != "" {
		return id
	}
	return available[0].ID
}

// ollamaModelProviderOptions is the parameter bundle for ollamaModelProvider.
type ollamaModelProviderOptions struct {
	modelID   string
	models    []ModelDef
	ollamaURL string
}

// ollamaModelProvider returns the provider for a model ID. If the model is
// found in the live list, its provider is returned. Otherwise, if an Ollama
// URL is configured and the model is not in the catalog at all, it is assumed
// to be an Ollama model.
func ollamaModelProvider(opts ollamaModelProviderOptions) string {
	modelID, models, ollamaURL := opts.modelID, opts.models, opts.ollamaURL
	for _, m := range models {
		if modelMatchesID(modelMatchesIDOptions{model: m, id: modelID}) {
			return m.Provider
		}
	}
	if strings.HasPrefix(modelID, ProviderOllama+"/") {
		return ProviderOllama
	}
	// Not in catalog — if Ollama is configured, assume it's an Ollama model.
	if ollamaURL != "" {
		return ProviderOllama
	}
	return ""
}

// resolveExplorationModel returns the model ID for sub-agents/exploration.
// When unset, prefers a cheap/fast provider-specific default (e.g. haiku for
// Anthropic) before falling back to resolveActiveModel.
func (c Config) resolveExplorationModel(models []ModelDef) string {
	return c.resolveExplorationModelResult(models).ResolvedModelID
}

func (c Config) resolveExplorationModelResult(models []ModelDef) configuredModelResolution {
	if c.ExplorationModel == "" {
		available := c.availableModels(models)
		if id := preferredDefault(preferredDefaultOptions{models: available, provider: c.defaultLangdagProvider(), defaults: defaultExplorationModels}); id != "" {
			return configuredModelResolution{ResolvedModelID: id}
		}
		return configuredModelResolution{ResolvedModelID: c.resolveActiveModel(models)}
	}
	available := c.availableModels(models)
	lookup := c.lookupConfiguredModelID(lookupConfiguredModelIDOptions{modelID: c.ExplorationModel, smartDefault: defaultCanonicalExplorationModel, available: available, models: models})
	if lookup.Status == configuredModelUsable {
		return lookup
	}
	// Configured but invalid — fall back.
	fallback := c.resolveActiveModel(models)
	return configuredModelResolution{
		ConfiguredModelID: c.ExplorationModel,
		ResolvedModelID:   fallback,
		Fallback:          true,
		Status:            lookup.Status,
		Diagnostic:        configuredModelDiagnostic(configuredModelDiagnosticOptions{field: "exploration_model", configured: c.ExplorationModel, fallback: fallback, status: lookup.Status}),
	}
}

type lookupConfiguredModelIDOptions struct {
	modelID      string
	smartDefault string
	available    []ModelDef
	models       []ModelDef
}

func (c Config) lookupConfiguredModelID(opts lookupConfiguredModelIDOptions) configuredModelResolution {
	modelID, smartDefault := opts.modelID, opts.smartDefault
	available, models := opts.available, opts.models
	candidates := modelIDCandidates(modelIDCandidatesOptions{modelID: modelID, smartDefault: smartDefault})
	availableMatches := uniqueModelsMatchingCandidates(uniqueModelsMatchingCandidatesOptions{models: available, candidates: candidates, exactOnly: true})
	switch len(availableMatches) {
	case 1:
		return configuredModelResolution{ConfiguredModelID: modelID, ResolvedModelID: availableMatches[0].ID, Status: configuredModelUsable}
	case 0:
	default:
		return configuredModelResolution{ConfiguredModelID: modelID, Status: configuredModelAmbiguous}
	}
	allMatches := uniqueModelsMatchingCandidates(uniqueModelsMatchingCandidatesOptions{models: models, candidates: candidates, exactOnly: true})
	switch len(allMatches) {
	case 1:
		return configuredModelResolution{ConfiguredModelID: modelID, Status: configuredModelUnavailable}
	case 0:
	default:
		return configuredModelResolution{ConfiguredModelID: modelID, Status: configuredModelAmbiguous}
	}

	availableMatches = uniqueModelsMatchingCandidates(uniqueModelsMatchingCandidatesOptions{models: available, candidates: candidates})
	switch len(availableMatches) {
	case 1:
		return configuredModelResolution{ConfiguredModelID: modelID, ResolvedModelID: availableMatches[0].ID, Status: configuredModelUsable}
	case 0:
	default:
		return configuredModelResolution{ConfiguredModelID: modelID, Status: configuredModelAmbiguous}
	}

	allMatches = uniqueModelsMatchingCandidates(uniqueModelsMatchingCandidatesOptions{models: models, candidates: candidates})
	switch len(allMatches) {
	case 1:
		return configuredModelResolution{ConfiguredModelID: modelID, Status: configuredModelUnavailable}
	case 0:
	default:
		return configuredModelResolution{ConfiguredModelID: modelID, Status: configuredModelAmbiguous}
	}

	if c.trustOfflineOllamaModel(trustOfflineOllamaModelOptions{modelID: modelID, models: models}) {
		return configuredModelResolution{ConfiguredModelID: modelID, ResolvedModelID: ollamaCanonicalModelID(modelID), Status: configuredModelUsable}
	}
	return configuredModelResolution{ConfiguredModelID: modelID, Status: configuredModelUnknown}
}

type uniqueModelsMatchingCandidatesOptions struct {
	models     []ModelDef
	candidates []string
	exactOnly  bool
}

func uniqueModelsMatchingCandidates(opts uniqueModelsMatchingCandidatesOptions) []ModelDef {
	models, candidates, exactOnly := opts.models, opts.candidates, opts.exactOnly
	seen := map[string]bool{}
	var matches []ModelDef
	for _, candidate := range candidates {
		for _, model := range modelsMatchingCandidate(modelsMatchingCandidateOptions{models: models, candidate: candidate, exactOnly: exactOnly}) {
			key := model.ID
			if key == "" {
				key = model.CanonicalID
			}
			if key == "" {
				key = candidate
			}
			if seen[key] {
				continue
			}
			seen[key] = true
			matches = append(matches, model)
		}
	}
	return matches
}

type modelsMatchingCandidateOptions struct {
	models    []ModelDef
	candidate string
	exactOnly bool
}

func modelsMatchingCandidate(opts modelsMatchingCandidateOptions) []ModelDef {
	models, candidate, exactOnly := opts.models, opts.candidate, opts.exactOnly
	var matches []ModelDef
	for _, model := range models {
		if model.ID == candidate || model.CanonicalID == candidate {
			matches = append(matches, model)
			continue
		}
		if exactOnly {
			continue
		}
		if modelMatchesID(modelMatchesIDOptions{model: model, id: candidate}) {
			matches = append(matches, model)
		}
	}
	return matches
}

type configuredModelDiagnosticOptions struct {
	field      string
	configured string
	fallback   string
	status     configuredModelLookupStatus
}

func configuredModelDiagnostic(opts configuredModelDiagnosticOptions) string {
	field, configured, fallback, status := opts.field, opts.configured, opts.fallback, opts.status
	reason := "not available"
	switch status {
	case configuredModelAmbiguous:
		reason = "ambiguous"
	case configuredModelUnavailable:
		reason = "unavailable"
	case configuredModelUnknown:
		reason = "unknown"
	}
	if fallback == "" {
		return fmt.Sprintf("project %s %q is %s; no fallback model is available", field, configured, reason)
	}
	return fmt.Sprintf("project %s %q is %s; using fallback model %q", field, configured, reason, fallback)
}

type trustOfflineOllamaModelOptions struct {
	modelID string
	models  []ModelDef
}

func (c Config) trustOfflineOllamaModel(opts trustOfflineOllamaModelOptions) bool {
	modelID, models := opts.modelID, opts.models
	if modelID == "" || !c.configuredDeploymentIDs()["ollama-local"] {
		return false
	}
	for _, model := range models {
		if modelMatchesID(modelMatchesIDOptions{model: model, id: modelID}) {
			return model.Provider == ProviderOllama || model.OwnerProvider == ProviderOllama
		}
	}
	return true
}

type configuredProviderForModelIDOptions struct {
	cfg     Config
	models  []ModelDef
	modelID string
}

func configuredProviderForModelID(opts configuredProviderForModelIDOptions) string {
	cfg, models, modelID := opts.cfg, opts.models, opts.modelID
	if modelID == "" {
		return ""
	}
	if model := findModelByID(findModelByIDOptions{models: models, id: modelID}); model != nil {
		return configuredProviderForModel(configuredProviderForModelOptions{cfg: cfg, model: *model})
	}
	return ollamaModelProvider(ollamaModelProviderOptions{modelID: modelID, models: models, ollamaURL: cfg.ollamaBaseURL()})
}

type modelIDCandidatesOptions struct {
	modelID      string
	smartDefault string
}

func modelIDCandidates(opts modelIDCandidatesOptions) []string {
	modelID, smartDefault := opts.modelID, opts.smartDefault
	seen := map[string]bool{}
	var candidates []string
	add := func(id string) {
		if id == "" || seen[id] {
			return
		}
		seen[id] = true
		candidates = append(candidates, id)
	}
	add(modelID)
	if strings.HasPrefix(modelID, ProviderOllama+"/") {
		add(strings.TrimPrefix(modelID, ProviderOllama+"/"))
	}
	if !looksCanonicalModelID(modelID) {
		migrated := migrateStoredModelIDToCanonical(migrateStoredModelIDToCanonicalOptions{
			savedModelID: modelID,
			offerings:    defaultModelIDMigrationOfferings(),
			smartDefault: smartDefault,
		})
		switch migrated.Status {
		case ModelIDMigrationCanonicalMatch, ModelIDMigrationUniqueNative:
			add(migrated.CanonicalModelID)
		}
	}
	for _, offering := range defaultModelIDMigrationOfferings() {
		if offering.CanonicalModelID == modelID {
			add(offering.NativeModelID)
		}
	}
	return candidates
}
