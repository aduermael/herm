// config.go handles loading, saving, and merging of global and per-project
// configuration for herm.
package main

import (
	_ "embed"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

const configDir = ".herm"
const configFile = "config.json"

type Config struct {
	ConfigVersion         int                         `json:"config_version,omitempty"`
	PasteCollapseMinChars int                         `json:"paste_collapse_min_chars"`
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
			routed, diagnostics, ok := routeAwareDeploymentsForModel(*c.Routing, filtered, configuredDeployments)
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

func routeAwareDeploymentsForModel(policy RoutingPolicy, model ModelDef, configuredDeployments map[string]bool) ([]ModelDeploymentDef, []string, bool) {
	providerID := model.OwnerProvider
	if providerID == "" {
		providerID = model.Provider
	}
	stages, source, ok := policy.routeFor(model.ID, providerID)
	if !ok {
		return nil, []string{"routing has no default/provider/model route for " + model.ID}, false
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
	return policy == nil || len(policy.Default) == 0 && len(policy.Providers) == 0 && len(policy.Models) == 0
}

func routingValidationIndexForConfigModels(cfg Config, models []ModelDef) RoutingValidationIndex {
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

func routingDiagnosticsForConfigModels(cfg Config, models []ModelDef) []RoutingDiagnostic {
	if cfg.Routing == nil {
		return nil
	}
	index := routingValidationIndexForConfigModels(cfg, models)
	diagnostics := cfg.Routing.validate(index)
	for _, model := range models {
		if model.ID == "" {
			continue
		}
		providerID := model.OwnerProvider
		if providerID == "" {
			providerID = model.Provider
		}
		stages, source, ok := cfg.Routing.routeFor(model.ID, providerID)
		if !ok {
			diagnostics = append(diagnostics, RoutingDiagnostic{
				Path:    "routing.effective." + model.ID,
				Code:    "no_effective_route",
				Message: "routing policy has no default, provider, or model route for this canonical model",
			})
			continue
		}
		if source == RouteSourceModel {
			continue
		}
		path := fmt.Sprintf("routing.effective.%s.%s", source, model.ID)
		diagnostics = append(diagnostics, validateRoutingStages(path, model.ID, stages, index)...)
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
		mergeDeploymentConfigFields(&current, deployment)
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
	return deploymentWithEnvFallbacks(deploymentID, deployment)
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
		if deploymentHasRequiredConfig(deploymentID, deployment) {
			configured[deploymentID] = true
		}
	}
	return configured
}

func deploymentHasRequiredConfig(deploymentID string, deployment DeploymentConfig) bool {
	deployment = deploymentWithEnvFallbacks(deploymentID, deployment)
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

func deploymentWithEnvFallbacks(deploymentID string, deployment DeploymentConfig) DeploymentConfig {
	for _, fallback := range deploymentEnvFallbacks[deploymentID] {
		value := deploymentFieldValue(deployment, fallback.Field)
		if value != "" {
			continue
		}
		for _, envName := range fallback.Env {
			if envValue := strings.TrimSpace(os.Getenv(envName)); envValue != "" {
				setDeploymentFieldValue(&deployment, fallback.Field, envValue)
				break
			}
		}
	}
	return deployment
}

func deploymentFieldValue(deployment DeploymentConfig, field string) string {
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

func setDeploymentFieldValue(deployment *DeploymentConfig, field, value string) {
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

func configuredProviderForModel(cfg Config, model ModelDef) string {
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
	candidates := modelIDCandidates(id, id)
	for _, m := range models {
		for _, candidate := range candidates {
			if modelMatchesID(m, candidate) {
				return m.ID
			}
		}
	}
	return ""
}

// resolveActiveModel returns a valid active model ID. If the current ActiveModel
// is invalid or its provider has no key, it falls back to the first available
// model, or empty string if no keys are configured.
func (c Config) resolveActiveModel(models []ModelDef) string {
	available := c.availableModels(models)
	if c.ActiveModel != "" {
		for _, candidate := range modelIDCandidates(c.ActiveModel, defaultCanonicalActiveModel) {
			if m := findModelByID(findModelByIDOptions{models: available, id: candidate}); m != nil {
				return m.ID
			}
		}
		if c.trustOfflineOllamaModel(c.ActiveModel, models) {
			return ollamaCanonicalModelID(c.ActiveModel)
		}
	}
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
		if modelMatchesID(m, modelID) {
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
	if c.ExplorationModel == "" {
		available := c.availableModels(models)
		if id := preferredDefault(preferredDefaultOptions{models: available, provider: c.defaultLangdagProvider(), defaults: defaultExplorationModels}); id != "" {
			return id
		}
		return c.resolveActiveModel(models)
	}
	available := c.availableModels(models)
	for _, candidate := range modelIDCandidates(c.ExplorationModel, defaultCanonicalExplorationModel) {
		if m := findModelByID(findModelByIDOptions{models: available, id: candidate}); m != nil {
			return m.ID
		}
	}
	if c.trustOfflineOllamaModel(c.ExplorationModel, models) {
		return ollamaCanonicalModelID(c.ExplorationModel)
	}
	// Configured but invalid — fall back.
	return c.resolveActiveModel(models)
}

func (c Config) trustOfflineOllamaModel(modelID string, models []ModelDef) bool {
	if modelID == "" || !c.configuredDeploymentIDs()["ollama-local"] {
		return false
	}
	for _, model := range models {
		if modelMatchesID(model, modelID) {
			return model.Provider == ProviderOllama || model.OwnerProvider == ProviderOllama
		}
	}
	return true
}

func configuredProviderForModelID(cfg Config, models []ModelDef, modelID string) string {
	if modelID == "" {
		return ""
	}
	if model := findModelByID(findModelByIDOptions{models: models, id: modelID}); model != nil {
		return configuredProviderForModel(cfg, *model)
	}
	return ollamaModelProvider(ollamaModelProviderOptions{modelID: modelID, models: models, ollamaURL: cfg.ollamaBaseURL()})
}

func modelIDCandidates(modelID, smartDefault string) []string {
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
		migrated := migrateStoredModelIDToCanonical(modelID, defaultModelIDMigrationOfferings(), smartDefault)
		switch migrated.Status {
		case ModelIDMigrationCanonicalMatch, ModelIDMigrationUniqueNative, ModelIDMigrationAmbiguousNative:
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

// ProjectConfig holds per-project overrides loaded from <repo>/.herm/config.json.
// Fields use omitempty so zero values mean "not overridden" (fall back to global).
type ProjectConfig struct {
	ActiveModel       string `json:"active_model,omitempty"`
	ExplorationModel  string `json:"exploration_model,omitempty"`
	Personality       string `json:"personality,omitempty"`
	SubAgentMaxTurns  int    `json:"sub_agent_max_turns,omitempty"`
	ExploreMaxTurns   int    `json:"explore_max_turns,omitempty"`
	GeneralMaxTurns   int    `json:"general_max_turns,omitempty"`
	MaxToolIterations int    `json:"max_tool_iterations,omitempty"`
	MaxAgentDepth     int    `json:"max_agent_depth,omitempty"`
	DebugMode         *bool  `json:"debug_mode,omitempty"` // nil = not overridden
	Thinking          *bool  `json:"thinking,omitempty"`   // nil = not overridden
}

// mergeConfigsOptions is the parameter bundle for mergeConfigs.
type mergeConfigsOptions struct {
	global  Config
	project ProjectConfig
}

// mergeConfigs overlays non-zero ProjectConfig fields onto a global Config.
func mergeConfigs(opts mergeConfigsOptions) Config {
	global, project := opts.global, opts.project
	merged := global
	if project.ActiveModel != "" {
		merged.ActiveModel = project.ActiveModel
	}
	if project.ExplorationModel != "" {
		merged.ExplorationModel = project.ExplorationModel
	}
	if project.Personality != "" {
		merged.Personality = project.Personality
	}
	if project.SubAgentMaxTurns != 0 {
		merged.SubAgentMaxTurns = project.SubAgentMaxTurns
	}
	if project.ExploreMaxTurns != 0 {
		merged.ExploreMaxTurns = project.ExploreMaxTurns
	}
	if project.GeneralMaxTurns != 0 {
		merged.GeneralMaxTurns = project.GeneralMaxTurns
	}
	if project.MaxToolIterations != 0 {
		merged.MaxToolIterations = project.MaxToolIterations
	}
	if project.MaxAgentDepth != 0 {
		merged.MaxAgentDepth = project.MaxAgentDepth
	}
	if project.DebugMode != nil {
		merged.DebugMode = *project.DebugMode
	}
	if project.Thinking != nil {
		merged.Thinking = project.Thinking
	}
	return merged
}

//go:embed container_version
var rawHermImageTag string

var hermImageTag = strings.TrimSpace(rawHermImageTag)
var defaultContainerImage = "aduermael/herm:" + hermImageTag

func defaultConfig() Config {
	return Config{
		ConfigVersion:         hermConfigVersionDeploymentAware,
		PasteCollapseMinChars: 200,
	}
}

func configPath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return filepath.Join(configDir, configFile)
	}
	return filepath.Join(home, configDir, configFile)
}

// ensureConfigDir creates the ~/.herm/ directory if it doesn't exist.
func ensureConfigDir() error {
	home, err := os.UserHomeDir()
	if err != nil {
		return fmt.Errorf("getting home dir: %w", err)
	}
	return os.MkdirAll(filepath.Join(home, configDir), 0o755)
}

// loadConfig reads config from ~/.herm/config.json.
// If the file doesn't exist, it creates it with defaults.
// If the file is malformed, it returns defaults.
// Merging: starts from defaults and overlays whatever the file contains,
// so new fields added later automatically get their default values.
func loadConfig() (Config, error) {
	cfg := defaultConfig()

	if err := ensureConfigDir(); err != nil {
		return cfg, fmt.Errorf("creating config dir: %w", err)
	}

	data, err := os.ReadFile(configPath())
	if os.IsNotExist(err) {
		// First run — write defaults
		if saveErr := saveConfig(cfg); saveErr != nil {
			return cfg, fmt.Errorf("writing default config: %w", saveErr)
		}
		return cfg, nil
	}
	if err != nil {
		return cfg, fmt.Errorf("reading config: %w", err)
	}

	// Unmarshal on top of defaults — missing fields keep their default values
	if err := json.Unmarshal(data, &cfg); err != nil {
		// Malformed JSON — return defaults
		return defaultConfig(), nil
	}

	return normalizeLoadedConfig(cfg), nil
}

// loadConfigFrom reads config from a specific directory path.
// Used for testing and custom config locations.
func loadConfigFrom(dir string) (Config, error) {
	cfg := defaultConfig()

	cfgDir := filepath.Join(dir, configDir)
	if err := os.MkdirAll(cfgDir, 0o755); err != nil {
		return cfg, fmt.Errorf("creating config dir: %w", err)
	}

	cfgPath := filepath.Join(cfgDir, configFile)
	data, err := os.ReadFile(cfgPath)
	if os.IsNotExist(err) {
		if saveErr := saveConfigTo(saveConfigToOptions{dir: dir, cfg: cfg}); saveErr != nil {
			return cfg, fmt.Errorf("writing default config: %w", saveErr)
		}
		return cfg, nil
	}
	if err != nil {
		return cfg, fmt.Errorf("reading config: %w", err)
	}

	if err := json.Unmarshal(data, &cfg); err != nil {
		return defaultConfig(), nil
	}

	return normalizeLoadedConfig(cfg), nil
}

func normalizeLoadedConfig(cfg Config) Config {
	cfg.ConfigVersion = hermConfigVersionDeploymentAware
	cfg.Deployments = deploymentConfigsForStorage(cfg)
	cfg.Routing = cloneRoutingPolicy(cfg.Routing)
	cfg = backfillLegacyConfigFieldsFromDeployments(cfg)
	cfg.ActiveModel = migrateLoadedModelID(cfg, cfg.ActiveModel, defaultCanonicalActiveModel)
	cfg.ExplorationModel = migrateLoadedModelID(cfg, cfg.ExplorationModel, defaultCanonicalExplorationModel)
	return cfg
}

func backfillLegacyConfigFieldsFromDeployments(cfg Config) Config {
	deployments := cfg.deploymentConfigs()
	cfg.AnthropicAPIKey = deployments["anthropic-direct"].APIKey
	cfg.OpenAIAPIKey = deployments["openai-direct"].APIKey
	cfg.GrokAPIKey = deployments["grok-direct"].APIKey
	cfg.OpenRouterAPIKey = deployments["openrouter"].APIKey
	cfg.GeminiAPIKey = deployments["gemini-direct"].APIKey
	cfg.OllamaBaseURL = deployments["ollama-local"].BaseURL
	return cfg
}

func migrateLoadedModelID(cfg Config, modelID, smartDefault string) string {
	if modelID == "" || looksCanonicalModelID(modelID) {
		return modelID
	}
	migrated := migrateStoredModelIDToCanonical(modelID, defaultModelIDMigrationOfferings(), smartDefault)
	switch migrated.Status {
	case ModelIDMigrationCanonicalMatch, ModelIDMigrationUniqueNative, ModelIDMigrationAmbiguousNative:
		return migrated.CanonicalModelID
	default:
		if cfg.configuredDeploymentIDs()["ollama-local"] {
			return ollamaCanonicalModelID(modelID)
		}
		return modelID
	}
}

// saveConfig writes config to ~/.herm/config.json.
func saveConfig(cfg Config) error {
	if err := ensureConfigDir(); err != nil {
		return fmt.Errorf("creating config dir: %w", err)
	}

	cfg = normalizeLoadedConfig(cfg)
	data, err := json.MarshalIndent(deploymentAwareConfigFromLegacyConfig(cfg), "", "  ")
	if err != nil {
		return fmt.Errorf("marshaling config: %w", err)
	}

	return os.WriteFile(configPath(), data, 0o644)
}

// saveConfigToOptions is the parameter bundle for saveConfigTo.
type saveConfigToOptions struct {
	dir string
	cfg Config
}

// saveConfigTo writes config to a specific directory path.
func saveConfigTo(opts saveConfigToOptions) error {
	dir, cfg := opts.dir, opts.cfg
	cfgDir := filepath.Join(dir, configDir)
	if err := os.MkdirAll(cfgDir, 0o755); err != nil {
		return fmt.Errorf("creating config dir: %w", err)
	}

	cfg = normalizeLoadedConfig(cfg)
	data, err := json.MarshalIndent(deploymentAwareConfigFromLegacyConfig(cfg), "", "  ")
	if err != nil {
		return fmt.Errorf("marshaling config: %w", err)
	}

	return os.WriteFile(filepath.Join(cfgDir, configFile), data, 0o644)
}

// loadProjectConfig reads project-level overrides from <repoRoot>/.herm/config.json.
// Returns an empty ProjectConfig if the file doesn't exist or is malformed.
func loadProjectConfig(repoRoot string) ProjectConfig {
	if repoRoot == "" {
		return ProjectConfig{}
	}
	data, err := os.ReadFile(filepath.Join(repoRoot, configDir, configFile))
	if err != nil {
		return ProjectConfig{}
	}
	var pc ProjectConfig
	if err := json.Unmarshal(data, &pc); err != nil {
		return ProjectConfig{}
	}
	pc.ActiveModel = migrateProjectModelID(pc.ActiveModel, defaultCanonicalActiveModel)
	pc.ExplorationModel = migrateProjectModelID(pc.ExplorationModel, defaultCanonicalExplorationModel)
	return pc
}

func migrateProjectModelID(modelID, smartDefault string) string {
	return migrateLoadedModelID(Config{}, modelID, smartDefault)
}

// saveProjectConfigOptions is the parameter bundle for saveProjectConfig.
type saveProjectConfigOptions struct {
	repoRoot string
	pc       ProjectConfig
}

// saveProjectConfig writes project-level overrides to <repoRoot>/.herm/config.json.
func saveProjectConfig(opts saveProjectConfigOptions) error {
	repoRoot, pc := opts.repoRoot, opts.pc
	cfgDir := filepath.Join(repoRoot, configDir)
	if err := os.MkdirAll(cfgDir, 0o755); err != nil {
		return fmt.Errorf("creating project config dir: %w", err)
	}
	pc.ActiveModel = migrateProjectModelID(pc.ActiveModel, defaultCanonicalActiveModel)
	pc.ExplorationModel = migrateProjectModelID(pc.ExplorationModel, defaultCanonicalExplorationModel)
	data, err := json.MarshalIndent(pc, "", "  ")
	if err != nil {
		return fmt.Errorf("marshaling project config: %w", err)
	}
	return os.WriteFile(filepath.Join(cfgDir, configFile), data, 0o644)
}
