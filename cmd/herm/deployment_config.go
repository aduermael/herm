// deployment_config.go defines deployment-aware config migration, routing
// validation, and canonical model ID normalization helpers.
package main

import (
	"encoding/json"
	"fmt"
	"sort"
	"strconv"
	"strings"
)

const hermConfigVersionDeploymentAware = 2

type DeploymentConfig struct {
	APIKey        string            `json:"api_key,omitempty"`
	BaseURL       string            `json:"base_url,omitempty"`
	Endpoint      string            `json:"endpoint,omitempty"`
	APIVersion    string            `json:"api_version,omitempty"`
	ProjectID     string            `json:"project_id,omitempty"`
	Region        string            `json:"region,omitempty"`
	ModelMappings map[string]string `json:"model_mappings,omitempty"`
}

type RoutingPolicy struct {
	Default   []RoutingStage            `json:"default,omitempty"`
	Providers map[string][]RoutingStage `json:"providers,omitempty"`
	Models    map[string][]RoutingStage `json:"models,omitempty"`
}

func (r RoutingPolicy) MarshalJSON() ([]byte, error) {
	out := map[string]any{}
	if r.Default != nil {
		out["default"] = r.Default
	}
	if len(r.Providers) > 0 {
		out["providers"] = r.Providers
	}
	if len(r.Models) > 0 {
		out["models"] = r.Models
	}
	return json.Marshal(out)
}

type RoutingStage struct {
	Deployments []DeploymentChoice `json:"deployments"`
	Retries     int                `json:"retries,omitempty"`
}

type DeploymentChoice struct {
	DeploymentID string `json:"deployment_id"`
	Weight       int    `json:"weight"`
}

type DeploymentAwareConfig struct {
	ConfigVersion         int                         `json:"config_version"`
	PasteCollapseMinChars int                         `json:"paste_collapse_min_chars,omitempty"`
	ActiveModel           string                      `json:"active_model,omitempty"`
	ExplorationModel      string                      `json:"exploration_model,omitempty"`
	Deployments           map[string]DeploymentConfig `json:"deployments,omitempty"`
	Routing               *RoutingPolicy              `json:"routing,omitempty"`
	ModelSortCol          string                      `json:"model_sort_col,omitempty"`
	ModelSortDirs         map[string]bool             `json:"model_sort_dirs,omitempty"`
	SubAgentMaxTurns      int                         `json:"sub_agent_max_turns,omitempty"`
	ExploreMaxTurns       int                         `json:"explore_max_turns,omitempty"`
	GeneralMaxTurns       int                         `json:"general_max_turns,omitempty"`
	MaxToolIterations     int                         `json:"max_tool_iterations,omitempty"`
	MaxAgentDepth         int                         `json:"max_agent_depth,omitempty"`
	Personality           string                      `json:"personality,omitempty"`
	HistoryMaxEntries     int                         `json:"history_max_entries,omitempty"`
	GitCoAuthor           *bool                       `json:"git_co_author,omitempty"`
	DebugMode             bool                        `json:"debug_mode,omitempty"`
	Thinking              *bool                       `json:"thinking,omitempty"`
}

type DeploymentEnvFallback struct {
	Field string
	Env   []string
}

type RoutingDiagnostic struct {
	Path    string
	Code    string
	Message string
}

type RouteSource string

const (
	RouteSourceModel    RouteSource = "model"
	RouteSourceProvider RouteSource = "provider"
	RouteSourceDefault  RouteSource = "default"
)

var deploymentEnvFallbacks = map[string][]DeploymentEnvFallback{
	"anthropic-direct": {
		{Field: "api_key", Env: []string{"ANTHROPIC_API_KEY"}},
	},
	"anthropic-bedrock": {
		{Field: "region", Env: []string{"AWS_REGION"}},
	},
	"anthropic-vertex": {
		{Field: "project_id", Env: []string{"VERTEX_PROJECT_ID"}},
		{Field: "region", Env: []string{"VERTEX_REGION"}},
	},
	"openai-direct": {
		{Field: "api_key", Env: []string{"OPENAI_API_KEY"}},
		{Field: "base_url", Env: []string{"OPENAI_BASE_URL"}},
	},
	"openai-azure": {
		{Field: "api_key", Env: []string{"AZURE_OPENAI_API_KEY"}},
		{Field: "endpoint", Env: []string{"AZURE_OPENAI_ENDPOINT"}},
		{Field: "api_version", Env: []string{"AZURE_OPENAI_API_VERSION"}},
	},
	"gemini-direct": {
		{Field: "api_key", Env: []string{"GEMINI_API_KEY"}},
	},
	"gemini-vertex": {
		{Field: "project_id", Env: []string{"VERTEX_PROJECT_ID"}},
		{Field: "region", Env: []string{"VERTEX_REGION"}},
	},
	"grok-direct": {
		{Field: "api_key", Env: []string{"XAI_API_KEY"}},
		{Field: "base_url", Env: []string{"XAI_BASE_URL"}},
	},
	"openrouter": {
		{Field: "api_key", Env: []string{"OPENROUTER_API_KEY"}},
		{Field: "base_url", Env: []string{"OPENROUTER_BASE_URL"}},
	},
	"ollama-local": {
		{Field: "base_url", Env: []string{"OLLAMA_BASE_URL"}},
	},
	"apple-local": {
		{Field: "base_url", Env: []string{"APPLE_FM_BASE_URL"}},
	},
}

func deploymentAwareConfigFromLegacyConfig(cfg Config) DeploymentAwareConfig {
	return migrateDeploymentAwareConfigFromLegacyConfig(DeploymentAwareConfigMigrationOptions{
		Config:                  cfg,
		Offerings:               defaultModelIDMigrationOfferings(),
		ActiveSmartDefault:      defaultCanonicalActiveModel,
		ExplorationSmartDefault: defaultCanonicalExplorationModel,
	}).Config
}

const defaultCanonicalActiveModel = "openai/gpt-4.1-2025-04-14"
const defaultCanonicalExplorationModel = "anthropic/claude-haiku-4-5"

type DeploymentAwareConfigMigrationOptions struct {
	Config                  Config
	Offerings               []ModelIDMigrationOffering
	ActiveSmartDefault      string
	ExplorationSmartDefault string
}

type DeploymentAwareConfigMigrationResult struct {
	Config           DeploymentAwareConfig
	ActiveModel      ModelIDMigrationResult
	ExplorationModel ModelIDMigrationResult
}

func migrateDeploymentAwareConfigFromLegacyConfig(opts DeploymentAwareConfigMigrationOptions) DeploymentAwareConfigMigrationResult {
	cfg := opts.Config
	offerings := opts.Offerings
	if len(offerings) == 0 {
		offerings = defaultModelIDMigrationOfferings()
	}
	activeDefault := opts.ActiveSmartDefault
	if activeDefault == "" {
		activeDefault = defaultCanonicalActiveModel
	}
	explorationDefault := opts.ExplorationSmartDefault
	if explorationDefault == "" {
		explorationDefault = activeDefault
	}
	active := ModelIDMigrationResult{}
	if cfg.ActiveModel != "" {
		active = migrateStoredModelIDToCanonical(migrateStoredModelIDToCanonicalOptions{
			savedModelID: cfg.ActiveModel,
			offerings:    offerings,
			smartDefault: activeDefault,
		})
	}
	exploration := ModelIDMigrationResult{}
	if cfg.ExplorationModel != "" {
		exploration = migrateStoredModelIDToCanonical(migrateStoredModelIDToCanonicalOptions{
			savedModelID: cfg.ExplorationModel,
			offerings:    offerings,
			smartDefault: explorationDefault,
		})
	}
	result := DeploymentAwareConfig{
		ConfigVersion:         hermConfigVersionDeploymentAware,
		PasteCollapseMinChars: cfg.PasteCollapseMinChars,
		ActiveModel:           active.CanonicalModelID,
		ExplorationModel:      exploration.CanonicalModelID,
		Deployments:           map[string]DeploymentConfig{},
		ModelSortCol:          cfg.ModelSortCol,
		ModelSortDirs:         cloneBoolMap(cfg.ModelSortDirs),
		SubAgentMaxTurns:      cfg.SubAgentMaxTurns,
		ExploreMaxTurns:       cfg.ExploreMaxTurns,
		GeneralMaxTurns:       cfg.GeneralMaxTurns,
		MaxToolIterations:     cfg.MaxToolIterations,
		MaxAgentDepth:         cfg.MaxAgentDepth,
		Personality:           cfg.Personality,
		HistoryMaxEntries:     cfg.HistoryMaxEntries,
		GitCoAuthor:           cloneBoolPtr(cfg.GitCoAuthor),
		DebugMode:             cfg.DebugMode,
		Thinking:              cloneBoolPtr(cfg.Thinking),
		Routing:               cloneRoutingPolicy(cfg.Routing),
	}
	result.Deployments = deploymentConfigsForStorage(cfg)
	if len(result.Deployments) == 0 {
		result.Deployments = nil
	}
	return DeploymentAwareConfigMigrationResult{Config: result, ActiveModel: active, ExplorationModel: exploration}
}

func deploymentConfigsForStorage(cfg Config) map[string]DeploymentConfig {
	out := map[string]DeploymentConfig{}
	for id, deployment := range cfg.Deployments {
		if !deploymentConfigIsEmpty(deployment) {
			out[id] = cloneDeploymentConfig(deployment)
		}
	}
	merge := func(id string, deployment DeploymentConfig) {
		current := out[id]
		mergeDeploymentConfigFields(mergeDeploymentConfigFieldsOptions{
			current:  &current,
			incoming: deployment,
		})
		if !deploymentConfigIsEmpty(current) {
			out[id] = current
		}
	}
	if cfg.AnthropicAPIKey != "" {
		merge("anthropic-direct", DeploymentConfig{APIKey: cfg.AnthropicAPIKey})
	}
	if cfg.OpenAIAPIKey != "" {
		merge("openai-direct", DeploymentConfig{APIKey: cfg.OpenAIAPIKey})
	}
	if cfg.GrokAPIKey != "" {
		merge("grok-direct", DeploymentConfig{APIKey: cfg.GrokAPIKey})
	}
	if cfg.OpenRouterAPIKey != "" {
		merge("openrouter", DeploymentConfig{APIKey: cfg.OpenRouterAPIKey})
	}
	if cfg.GeminiAPIKey != "" {
		merge("gemini-direct", DeploymentConfig{APIKey: cfg.GeminiAPIKey})
	}
	if cfg.OllamaBaseURL != "" {
		merge("ollama-local", DeploymentConfig{BaseURL: cfg.OllamaBaseURL})
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

type mergeDeploymentConfigFieldsOptions struct {
	current  *DeploymentConfig
	incoming DeploymentConfig
}

func mergeDeploymentConfigFields(opts mergeDeploymentConfigFieldsOptions) {
	current := opts.current
	incoming := opts.incoming
	if current.APIKey == "" {
		current.APIKey = incoming.APIKey
	}
	if current.BaseURL == "" {
		current.BaseURL = incoming.BaseURL
	}
	if current.Endpoint == "" {
		current.Endpoint = incoming.Endpoint
	}
	if current.APIVersion == "" {
		current.APIVersion = incoming.APIVersion
	}
	if current.ProjectID == "" {
		current.ProjectID = incoming.ProjectID
	}
	if current.Region == "" {
		current.Region = incoming.Region
	}
	if len(current.ModelMappings) == 0 {
		current.ModelMappings = cloneStringMap(incoming.ModelMappings)
	}
}

func deploymentConfigIsEmpty(deployment DeploymentConfig) bool {
	return deployment.APIKey == "" &&
		deployment.BaseURL == "" &&
		deployment.Endpoint == "" &&
		deployment.APIVersion == "" &&
		deployment.ProjectID == "" &&
		deployment.Region == "" &&
		len(deployment.ModelMappings) == 0
}

func cloneRoutingPolicy(policy *RoutingPolicy) *RoutingPolicy {
	if policy == nil {
		return nil
	}
	clone := &RoutingPolicy{
		Default:   cloneRoutingStages(policy.Default),
		Providers: map[string][]RoutingStage{},
		Models:    map[string][]RoutingStage{},
	}
	for providerID, stages := range policy.Providers {
		clone.Providers[providerID] = cloneRoutingStages(stages)
	}
	for modelID, stages := range policy.Models {
		clone.Models[modelID] = cloneRoutingStages(stages)
	}
	if policy.Default == nil {
		clone.Default = nil
	}
	if len(clone.Providers) == 0 {
		clone.Providers = nil
	}
	if len(clone.Models) == 0 {
		clone.Models = nil
	}
	if clone.Default == nil && len(clone.Providers) == 0 && len(clone.Models) == 0 {
		return nil
	}
	return clone
}

func cloneRoutingStages(stages []RoutingStage) []RoutingStage {
	if stages == nil {
		return nil
	}
	clone := make([]RoutingStage, len(stages))
	for i, stage := range stages {
		clone[i] = RoutingStage{
			Deployments: append([]DeploymentChoice(nil), stage.Deployments...),
			Retries:     stage.Retries,
		}
	}
	return clone
}

type mergeDeploymentAwareProjectConfigOptions struct {
	global  DeploymentAwareConfig
	project ProjectConfig
}

func mergeDeploymentAwareProjectConfig(opts mergeDeploymentAwareProjectConfigOptions) DeploymentAwareConfig {
	merged := opts.global
	project := opts.project
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
		merged.Thinking = cloneBoolPtr(project.Thinking)
	}
	return merged
}

func cloneBoolMap(values map[string]bool) map[string]bool {
	if len(values) == 0 {
		return nil
	}
	clone := make(map[string]bool, len(values))
	for key, value := range values {
		clone[key] = value
	}
	return clone
}

func cloneBoolPtr(value *bool) *bool {
	if value == nil {
		return nil
	}
	clone := *value
	return &clone
}

func defaultModelIDMigrationOfferings() []ModelIDMigrationOffering {
	offerings := []ModelIDMigrationOffering{
		{CanonicalModelID: "anthropic/claude-sonnet-4-20250514", DeploymentID: "anthropic-direct", NativeModelID: "claude-sonnet-4-20250514"},
		{CanonicalModelID: "anthropic/claude-sonnet-4-6", DeploymentID: "anthropic-direct", NativeModelID: "claude-sonnet-4-6"},
		{CanonicalModelID: "anthropic/claude-opus-4-6", DeploymentID: "anthropic-direct", NativeModelID: "claude-opus-4-6"},
		{CanonicalModelID: "anthropic/claude-haiku-4-5", DeploymentID: "anthropic-direct", NativeModelID: "claude-haiku-4-5"},
		{CanonicalModelID: "openai/gpt-4.1-2025-04-14", DeploymentID: "openai-direct", NativeModelID: "gpt-4.1-2025-04-14"},
		{CanonicalModelID: "openai/gpt-4.1-mini-2025-04-14", DeploymentID: "openai-direct", NativeModelID: "gpt-4.1-mini-2025-04-14"},
		{CanonicalModelID: "google/gemini-2.5-pro", DeploymentID: "gemini-direct", NativeModelID: "gemini-2.5-pro"},
		{CanonicalModelID: "google/gemini-2.5-flash", DeploymentID: "gemini-direct", NativeModelID: "gemini-2.5-flash"},
		{CanonicalModelID: "xai/grok-4-1-fast-reasoning", DeploymentID: "grok-direct", NativeModelID: "grok-4-1-fast-reasoning"},
		{CanonicalModelID: "xai/grok-4-1-fast-non-reasoning", DeploymentID: "grok-direct", NativeModelID: "grok-4-1-fast-non-reasoning"},
		{CanonicalModelID: "z-ai/glm-4.5-air:free", DeploymentID: "openrouter", NativeModelID: "z-ai/glm-4.5-air:free"},
	}
	offerings = append(offerings, embeddedCatalogModelIDMigrationOfferings()...)
	return uniqueModelIDMigrationOfferings(offerings)
}

type routeForOptions struct {
	canonicalModelID string
	providerID       string
}

func (r RoutingPolicy) routeFor(opts routeForOptions) ([]RoutingStage, RouteSource, bool) {
	canonicalModelID := opts.canonicalModelID
	providerID := canonicalProviderID(opts.providerID)
	if r.Models != nil {
		if stages, ok := r.Models[canonicalModelID]; ok {
			return stages, RouteSourceModel, true
		}
	}
	if r.Providers != nil {
		if stages, ok := r.Providers[providerID]; ok {
			return stages, RouteSourceProvider, true
		}
		for key, stages := range r.Providers {
			if canonicalProviderID(key) == providerID {
				return stages, RouteSourceProvider, true
			}
		}
	}
	if r.Default != nil {
		return r.Default, RouteSourceDefault, true
	}
	return nil, "", false
}

type RoutingValidationIndex struct {
	KnownProviders             map[string]bool
	KnownDeployments           map[string]bool
	AvailableDeployments       map[string]bool
	EligibleDeploymentsByModel map[string]map[string]bool
	MissingMappingsByModel     map[string]map[string]bool
}

func (r RoutingPolicy) validate(index RoutingValidationIndex) []RoutingDiagnostic {
	knownProviders := index.KnownProviders
	if len(knownProviders) == 0 {
		knownProviders = knownCanonicalProviderIDs()
	}
	var diagnostics []RoutingDiagnostic
	if r.Default != nil {
		diagnostics = append(diagnostics, validateRoutingStages(validateRoutingStagesOptions{
			path:   "routing.default",
			stages: r.Default,
			index:  index,
		})...)
	}
	for providerID, stages := range r.Providers {
		canonical := canonicalProviderID(providerID)
		switch {
		case providerID == "":
			diagnostics = append(diagnostics, RoutingDiagnostic{Path: "routing.providers", Code: "empty_provider_id", Message: "provider route key must not be empty"})
			continue
		case canonical == "" || !knownProviders[canonical]:
			diagnostics = append(diagnostics, RoutingDiagnostic{Path: "routing.providers." + providerID, Code: "unknown_provider", Message: "provider route key is not a known catalog provider"})
			continue
		}
		diagnostics = append(diagnostics, validateRoutingStages(validateRoutingStagesOptions{
			path:   "routing.providers." + providerID,
			stages: stages,
			index:  index,
		})...)
	}
	for canonicalModelID, stages := range r.Models {
		if !looksCanonicalModelID(canonicalModelID) {
			diagnostics = append(diagnostics, RoutingDiagnostic{Path: "routing.models." + canonicalModelID, Code: "invalid_canonical_model_id", Message: "model route key must be an owner-qualified canonical model id"})
			continue
		}
		diagnostics = append(diagnostics, validateRoutingStages(validateRoutingStagesOptions{
			path:             "routing.models." + canonicalModelID,
			canonicalModelID: canonicalModelID,
			stages:           stages,
			index:            index,
		})...)
	}
	sortRoutingDiagnostics(diagnostics)
	return diagnostics
}

type validateRoutingStagesOptions struct {
	path             string
	canonicalModelID string
	stages           []RoutingStage
	index            RoutingValidationIndex
}

func validateRoutingStages(opts validateRoutingStagesOptions) []RoutingDiagnostic {
	path := opts.path
	canonicalModelID := opts.canonicalModelID
	stages := opts.stages
	index := opts.index
	knownDeployments := index.KnownDeployments
	if len(knownDeployments) == 0 {
		knownDeployments = knownDeploymentIDs()
	}
	availableDeployments := index.AvailableDeployments
	var diagnostics []RoutingDiagnostic
	if len(stages) == 0 {
		return []RoutingDiagnostic{{
			Path:    path,
			Code:    "empty_override",
			Message: "route override is authoritative and contains no stages",
		}}
	}
	for i, stage := range stages {
		stagePath := fmt.Sprintf("%s[%d]", path, i)
		eligibleCount := 0
		if stage.Retries < 0 {
			diagnostics = append(diagnostics, RoutingDiagnostic{
				Path:    stagePath + ".retries",
				Code:    "negative_retries",
				Message: "retries must be zero or greater",
			})
		}
		if len(stage.Deployments) == 0 {
			diagnostics = append(diagnostics, RoutingDiagnostic{
				Path:    stagePath + ".deployments",
				Code:    "empty_stage",
				Message: "route stage must include at least one deployment choice",
			})
			continue
		}
		for j, choice := range stage.Deployments {
			choicePath := fmt.Sprintf("%s.deployments[%d]", stagePath, j)
			if choice.DeploymentID == "" {
				diagnostics = append(diagnostics, RoutingDiagnostic{
					Path:    choicePath + ".deployment_id",
					Code:    "missing_deployment_id",
					Message: "deployment_id is required",
				})
			} else if !knownDeployments[choice.DeploymentID] {
				diagnostics = append(diagnostics, RoutingDiagnostic{
					Path:    choicePath + ".deployment_id",
					Code:    "unknown_deployment",
					Message: "deployment is not present in the catalog",
				})
			} else if availableDeployments != nil && !availableDeployments[choice.DeploymentID] {
				diagnostics = append(diagnostics, RoutingDiagnostic{
					Path:    choicePath + ".deployment_id",
					Code:    "unavailable_deployment",
					Message: "deployment is configured in routing but is not locally available",
				})
			}
			if choice.Weight <= 0 {
				diagnostics = append(diagnostics, RoutingDiagnostic{
					Path:    choicePath + ".weight",
					Code:    "non_positive_weight",
					Message: "weight must be greater than zero",
				})
			}
			if choice.DeploymentID != "" && knownDeployments[choice.DeploymentID] && (availableDeployments == nil || availableDeployments[choice.DeploymentID]) && choice.Weight > 0 {
				if canonicalModelID == "" || deploymentCanServeModel(deploymentCanServeModelOptions{
					canonicalModelID:           canonicalModelID,
					deploymentID:               choice.DeploymentID,
					eligibleDeploymentsByModel: index.EligibleDeploymentsByModel,
				}) {
					eligibleCount++
				} else if deploymentNeedsModelMapping(deploymentNeedsModelMappingOptions{
					canonicalModelID:       canonicalModelID,
					deploymentID:           choice.DeploymentID,
					missingMappingsByModel: index.MissingMappingsByModel,
				}) {
					diagnostics = append(diagnostics, RoutingDiagnostic{
						Path:    choicePath + ".deployment_id",
						Code:    "missing_model_mapping",
						Message: "deployment requires model_mappings for this canonical model",
					})
				} else {
					diagnostics = append(diagnostics, RoutingDiagnostic{
						Path:    choicePath + ".deployment_id",
						Code:    "ineligible_deployment",
						Message: "deployment cannot serve this canonical model",
					})
				}
			}
		}
		if canonicalModelID != "" && len(stage.Deployments) > 0 && eligibleCount == 0 {
			diagnostics = append(diagnostics, RoutingDiagnostic{
				Path:    stagePath + ".deployments",
				Code:    "no_eligible_deployments",
				Message: "route stage has no deployment choices that can serve this canonical model",
			})
		}
	}
	return diagnostics
}

type ModelIDMigrationStatus string

const (
	ModelIDMigrationCanonicalMatch  ModelIDMigrationStatus = "canonical_match"
	ModelIDMigrationUniqueNative    ModelIDMigrationStatus = "unique_native_match"
	ModelIDMigrationAmbiguousNative ModelIDMigrationStatus = "ambiguous_native_match"
	ModelIDMigrationFallback        ModelIDMigrationStatus = "smart_default_fallback"
)

type ModelIDMigrationOffering struct {
	CanonicalModelID string
	DeploymentID     string
	NativeModelID    string
}

type ModelIDMigrationResult struct {
	CanonicalModelID string
	Status           ModelIDMigrationStatus
	Diagnostic       string
}

type migrateStoredModelIDToCanonicalOptions struct {
	savedModelID string
	offerings    []ModelIDMigrationOffering
	smartDefault string
}

func migrateStoredModelIDToCanonical(opts migrateStoredModelIDToCanonicalOptions) ModelIDMigrationResult {
	savedModelID := opts.savedModelID
	offerings := opts.offerings
	smartDefault := opts.smartDefault
	if savedModelID != "" {
		canonicalSeen := map[string]bool{}
		for _, offering := range offerings {
			canonicalSeen[offering.CanonicalModelID] = true
		}
		matches := make([]ModelIDMigrationOffering, 0, 1)
		for _, offering := range offerings {
			if offering.NativeModelID == savedModelID {
				matches = append(matches, offering)
			}
		}
		uniqueCanonical := ""
		for _, match := range matches {
			if uniqueCanonical == "" {
				uniqueCanonical = match.CanonicalModelID
			} else if uniqueCanonical != match.CanonicalModelID {
				uniqueCanonical = ""
				break
			}
		}
		if canonicalSeen[savedModelID] {
			return ModelIDMigrationResult{CanonicalModelID: savedModelID, Status: ModelIDMigrationCanonicalMatch}
		}
		if uniqueCanonical != "" && uniqueCanonical != savedModelID {
			return ModelIDMigrationResult{CanonicalModelID: uniqueCanonical, Status: ModelIDMigrationUniqueNative}
		}
		if len(matches) > 1 {
			return ModelIDMigrationResult{
				CanonicalModelID: smartDefault,
				Status:           ModelIDMigrationAmbiguousNative,
				Diagnostic:       "saved native model ID matches multiple canonical models",
			}
		}
		if looksCanonicalModelID(savedModelID) {
			return ModelIDMigrationResult{CanonicalModelID: savedModelID, Status: ModelIDMigrationCanonicalMatch}
		}
		if uniqueCanonical != "" {
			return ModelIDMigrationResult{CanonicalModelID: uniqueCanonical, Status: ModelIDMigrationUniqueNative}
		}
	}
	return ModelIDMigrationResult{
		CanonicalModelID: smartDefault,
		Status:           ModelIDMigrationFallback,
		Diagnostic:       "saved model ID could not be mapped deterministically",
	}
}

func looksCanonicalModelID(value string) bool {
	owner, model, ok := strings.Cut(value, "/")
	return ok && owner != "" && model != "" && !strings.ContainsAny(value, " \t\r\n")
}

func canonicalProviderID(providerID string) string {
	switch providerID {
	case "gemini":
		return "google"
	case "grok":
		return "xai"
	default:
		return providerID
	}
}

func knownCanonicalProviderIDs() map[string]bool {
	return map[string]bool{
		"anthropic":  true,
		"openai":     true,
		"google":     true,
		"xai":        true,
		"z-ai":       true,
		"openrouter": true,
		"ollama":     true,
		"apple":      true,
	}
}

func knownDeploymentIDs() map[string]bool {
	return map[string]bool{
		"anthropic-direct":  true,
		"anthropic-bedrock": true,
		"anthropic-vertex":  true,
		"openai-direct":     true,
		"openai-azure":      true,
		"gemini-direct":     true,
		"gemini-vertex":     true,
		"grok-direct":       true,
		"openrouter":        true,
		"ollama-local":      true,
		"apple-local":       true,
	}
}

type deploymentCanServeModelOptions struct {
	canonicalModelID           string
	deploymentID               string
	eligibleDeploymentsByModel map[string]map[string]bool
}

func deploymentCanServeModel(opts deploymentCanServeModelOptions) bool {
	eligibleDeploymentsByModel := opts.eligibleDeploymentsByModel
	if len(eligibleDeploymentsByModel) == 0 {
		return true
	}
	eligible := eligibleDeploymentsByModel[opts.canonicalModelID]
	if eligible == nil {
		return false
	}
	return eligible[opts.deploymentID]
}

type deploymentNeedsModelMappingOptions struct {
	canonicalModelID       string
	deploymentID           string
	missingMappingsByModel map[string]map[string]bool
}

func deploymentNeedsModelMapping(opts deploymentNeedsModelMappingOptions) bool {
	missing := opts.missingMappingsByModel[opts.canonicalModelID]
	if missing == nil {
		return false
	}
	return missing[opts.deploymentID]
}

func sortRoutingDiagnostics(diagnostics []RoutingDiagnostic) {
	sort.Slice(diagnostics, func(i, j int) bool {
		if diagnostics[i].Path == diagnostics[j].Path {
			return diagnostics[i].Code < diagnostics[j].Code
		}
		return diagnostics[i].Path < diagnostics[j].Path
	})
}

func formatRoutingStages(stages []RoutingStage) string {
	if len(stages) == 0 {
		return ""
	}
	parts := make([]string, 0, len(stages))
	for _, stage := range stages {
		choices := make([]string, 0, len(stage.Deployments))
		for _, choice := range stage.Deployments {
			if choice.DeploymentID == "" {
				continue
			}
			weight := choice.Weight
			if weight == 0 {
				weight = 100
			}
			choices = append(choices, fmt.Sprintf("%s:%d", choice.DeploymentID, weight))
		}
		if len(choices) == 0 {
			continue
		}
		part := strings.Join(choices, ",")
		if stage.Retries > 0 {
			part += fmt.Sprintf("@%d", stage.Retries)
		}
		parts = append(parts, part)
	}
	return strings.Join(parts, " | ")
}

func parseRoutingStages(value string) ([]RoutingStage, error) {
	value = strings.TrimSpace(value)
	if value == "" {
		return nil, nil
	}
	rawStages := strings.Split(value, "|")
	stages := make([]RoutingStage, 0, len(rawStages))
	for _, rawStage := range rawStages {
		rawStage = strings.TrimSpace(rawStage)
		if rawStage == "" {
			continue
		}
		retries := 0
		if idx := strings.LastIndex(rawStage, "@"); idx >= 0 {
			rawRetries := strings.TrimSpace(rawStage[idx+1:])
			n, err := strconv.Atoi(rawRetries)
			if err != nil || n < 0 {
				return nil, fmt.Errorf("invalid retry count %q", rawRetries)
			}
			retries = n
			rawStage = strings.TrimSpace(rawStage[:idx])
		}
		rawChoices := strings.Split(rawStage, ",")
		stage := RoutingStage{Retries: retries}
		for _, rawChoice := range rawChoices {
			rawChoice = strings.TrimSpace(rawChoice)
			if rawChoice == "" {
				continue
			}
			deploymentID := rawChoice
			weight := 100
			if id, rawWeight, ok := strings.Cut(rawChoice, ":"); ok {
				deploymentID = strings.TrimSpace(id)
				n, err := strconv.Atoi(strings.TrimSpace(rawWeight))
				if err != nil {
					return nil, fmt.Errorf("invalid weight %q", rawWeight)
				}
				weight = n
			}
			if deploymentID == "" {
				return nil, fmt.Errorf("deployment_id is required")
			}
			stage.Deployments = append(stage.Deployments, DeploymentChoice{DeploymentID: deploymentID, Weight: weight})
		}
		if len(stage.Deployments) == 0 {
			continue
		}
		stages = append(stages, stage)
	}
	return stages, nil
}
