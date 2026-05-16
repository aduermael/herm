// config_storage.go loads, saves, migrates, and merges global and project
// configuration files.
package main

import (
	_ "embed"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

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

func projectConfigPath(repoRoot string) string {
	return filepath.Join(repoRoot, configDir, configFile)
}

func projectConfigScopeAvailable(repoRoot string) bool {
	if repoRoot == "" {
		return false
	}
	return !sameFilesystemPath(sameFilesystemPathOptions{pathA: projectConfigPath(repoRoot), pathB: configPath()})
}

type sameFilesystemPathOptions struct {
	pathA string
	pathB string
}

func sameFilesystemPath(opts sameFilesystemPathOptions) bool {
	a, b := opts.pathA, opts.pathB
	if a == "" || b == "" {
		return false
	}
	a = bestEffortRealPath(a)
	b = bestEffortRealPath(b)
	if a == b {
		return true
	}
	statA, errA := os.Stat(a)
	statB, errB := os.Stat(b)
	return errA == nil && errB == nil && os.SameFile(statA, statB)
}

func bestEffortRealPath(path string) string {
	if path == "" {
		return ""
	}
	if abs, err := filepath.Abs(path); err == nil {
		path = abs
	}
	path = filepath.Clean(path)
	if eval, err := filepath.EvalSymlinks(path); err == nil {
		return filepath.Clean(eval)
	}

	current := path
	var suffix []string
	for {
		parent := filepath.Dir(current)
		if parent == current {
			break
		}
		suffix = append(suffix, filepath.Base(current))
		current = parent
		if eval, err := filepath.EvalSymlinks(current); err == nil {
			realPath := filepath.Clean(eval)
			for i := len(suffix) - 1; i >= 0; i-- {
				realPath = filepath.Join(realPath, suffix[i])
			}
			return filepath.Clean(realPath)
		}
	}

	return path
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
		// First run: write defaults.
		if saveErr := saveConfig(cfg); saveErr != nil {
			return cfg, fmt.Errorf("writing default config: %w", saveErr)
		}
		return cfg, nil
	}
	if err != nil {
		return cfg, fmt.Errorf("reading config: %w", err)
	}

	// Unmarshal on top of defaults; missing fields keep their default values.
	if err := json.Unmarshal(data, &cfg); err != nil {
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
	cfg.ActiveModel = migrateLoadedModelIDWithOfferings(migrateLoadedModelIDOptions{cfg: cfg, modelID: cfg.ActiveModel, smartDefault: defaultCanonicalActiveModel, offerings: defaultModelIDMigrationOfferings()})
	cfg.ExplorationModel = migrateLoadedModelIDWithOfferings(migrateLoadedModelIDOptions{cfg: cfg, modelID: cfg.ExplorationModel, smartDefault: defaultCanonicalExplorationModel, offerings: defaultModelIDMigrationOfferings()})
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

type migrateLoadedModelIDOptions struct {
	cfg          Config
	modelID      string
	smartDefault string
	offerings    []ModelIDMigrationOffering
}

func migrateLoadedModelID(opts migrateLoadedModelIDOptions) string {
	opts.offerings = defaultModelIDMigrationOfferings()
	return migrateLoadedModelIDWithOfferings(opts)
}

func migrateLoadedModelIDWithOfferings(opts migrateLoadedModelIDOptions) string {
	cfg, modelID, smartDefault := opts.cfg, opts.modelID, opts.smartDefault
	offerings := opts.offerings
	if modelID == "" || looksCanonicalModelID(modelID) {
		migrated := migrateStoredModelIDToCanonical(migrateStoredModelIDToCanonicalOptions{
			savedModelID: modelID,
			offerings:    offerings,
			smartDefault: smartDefault,
		})
		if migrated.Status == ModelIDMigrationUniqueNative {
			return migrated.CanonicalModelID
		}
		return modelID
	}
	migrated := migrateStoredModelIDToCanonical(migrateStoredModelIDToCanonicalOptions{
		savedModelID: modelID,
		offerings:    offerings,
		smartDefault: smartDefault,
	})
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

func normalizeConfigForModels(opts configModelsOptions) Config {
	cfg, models := opts.cfg, opts.models
	offerings := defaultModelIDMigrationOfferings()
	offerings = append(offerings, modelIDMigrationOfferingsFromModels(models)...)
	cfg.ActiveModel = migrateLoadedModelIDWithOfferings(migrateLoadedModelIDOptions{cfg: cfg, modelID: cfg.ActiveModel, smartDefault: defaultCanonicalActiveModel, offerings: offerings})
	cfg.ExplorationModel = migrateLoadedModelIDWithOfferings(migrateLoadedModelIDOptions{cfg: cfg, modelID: cfg.ExplorationModel, smartDefault: defaultCanonicalExplorationModel, offerings: offerings})
	return cfg
}

type normalizeConfigModelIDForModelsOptions struct {
	cfg          Config
	modelID      string
	smartDefault string
	models       []ModelDef
}

func normalizeConfigModelIDForModels(opts normalizeConfigModelIDForModelsOptions) string {
	offerings := defaultModelIDMigrationOfferings()
	offerings = append(offerings, modelIDMigrationOfferingsFromModels(opts.models)...)
	return migrateLoadedModelIDWithOfferings(migrateLoadedModelIDOptions{cfg: opts.cfg, modelID: opts.modelID, smartDefault: opts.smartDefault, offerings: offerings})
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
	pc, ok := readProjectConfig(repoRoot)
	if !ok {
		return ProjectConfig{}
	}
	return normalizeProjectConfig(pc)
}

type loadProjectConfigForModelsOptions struct {
	repoRoot string
	models   []ModelDef
}

func loadProjectConfigForModels(opts loadProjectConfigForModelsOptions) ProjectConfig {
	pc, ok := readProjectConfig(opts.repoRoot)
	if !ok {
		return ProjectConfig{}
	}
	return normalizeProjectConfigForModels(normalizeProjectConfigForModelsOptions{pc: pc, models: opts.models})
}

func loadRawProjectConfig(repoRoot string) ProjectConfig {
	pc, ok := readProjectConfig(repoRoot)
	if !ok {
		return ProjectConfig{}
	}
	return pc
}

func readProjectConfig(repoRoot string) (ProjectConfig, bool) {
	if !projectConfigScopeAvailable(repoRoot) {
		return ProjectConfig{}, false
	}
	data, err := os.ReadFile(projectConfigPath(repoRoot))
	if err != nil {
		return ProjectConfig{}, false
	}
	var pc ProjectConfig
	if err := json.Unmarshal(data, &pc); err != nil {
		return ProjectConfig{}, false
	}
	return pc, true
}

type migrateProjectModelIDOptions struct {
	modelID      string
	smartDefault string
	offerings    []ModelIDMigrationOffering
}

func migrateProjectModelID(opts migrateProjectModelIDOptions) string {
	opts.offerings = defaultModelIDMigrationOfferings()
	return migrateProjectModelIDWithOfferings(opts)
}

func migrateProjectModelIDWithOfferings(opts migrateProjectModelIDOptions) string {
	modelID, smartDefault, offerings := opts.modelID, opts.smartDefault, opts.offerings
	if modelID == "" {
		return modelID
	}
	migrated := migrateStoredModelIDToCanonical(migrateStoredModelIDToCanonicalOptions{
		savedModelID: modelID,
		offerings:    offerings,
		smartDefault: smartDefault,
	})
	switch migrated.Status {
	case ModelIDMigrationCanonicalMatch, ModelIDMigrationUniqueNative:
		return migrated.CanonicalModelID
	default:
		return modelID
	}
}

func normalizeProjectConfig(pc ProjectConfig) ProjectConfig {
	return normalizeProjectConfigWithOfferings(normalizeProjectConfigWithOfferingsOptions{pc: pc, offerings: defaultModelIDMigrationOfferings()})
}

type normalizeProjectConfigForModelsOptions struct {
	pc     ProjectConfig
	models []ModelDef
}

func normalizeProjectConfigForModels(opts normalizeProjectConfigForModelsOptions) ProjectConfig {
	offerings := defaultModelIDMigrationOfferings()
	offerings = append(offerings, modelIDMigrationOfferingsFromModels(opts.models)...)
	return normalizeProjectConfigWithOfferings(normalizeProjectConfigWithOfferingsOptions{pc: opts.pc, offerings: offerings})
}

type normalizeProjectModelIDForModelsOptions struct {
	modelID      string
	smartDefault string
	models       []ModelDef
}

func normalizeProjectModelIDForModels(opts normalizeProjectModelIDForModelsOptions) string {
	offerings := defaultModelIDMigrationOfferings()
	offerings = append(offerings, modelIDMigrationOfferingsFromModels(opts.models)...)
	return migrateProjectModelIDWithOfferings(migrateProjectModelIDOptions{modelID: opts.modelID, smartDefault: opts.smartDefault, offerings: offerings})
}

type normalizeProjectConfigWithOfferingsOptions struct {
	pc        ProjectConfig
	offerings []ModelIDMigrationOffering
}

func normalizeProjectConfigWithOfferings(opts normalizeProjectConfigWithOfferingsOptions) ProjectConfig {
	pc, offerings := opts.pc, opts.offerings
	pc.ActiveModel = migrateProjectModelIDWithOfferings(migrateProjectModelIDOptions{modelID: pc.ActiveModel, smartDefault: defaultCanonicalActiveModel, offerings: offerings})
	pc.ExplorationModel = migrateProjectModelIDWithOfferings(migrateProjectModelIDOptions{modelID: pc.ExplorationModel, smartDefault: defaultCanonicalExplorationModel, offerings: offerings})
	return pc
}

// saveProjectConfigOptions is the parameter bundle for saveProjectConfig.
type saveProjectConfigOptions struct {
	repoRoot string
	pc       ProjectConfig
	models   []ModelDef
}

// saveProjectConfig writes project-level overrides to <repoRoot>/.herm/config.json.
func saveProjectConfig(opts saveProjectConfigOptions) error {
	repoRoot, pc := opts.repoRoot, opts.pc
	if !projectConfigScopeAvailable(repoRoot) {
		return fmt.Errorf("project config path is unavailable or collides with global config")
	}
	cfgDir := filepath.Join(repoRoot, configDir)
	if err := os.MkdirAll(cfgDir, 0o755); err != nil {
		return fmt.Errorf("creating project config dir: %w", err)
	}
	if opts.models != nil {
		pc = normalizeProjectConfigForModels(normalizeProjectConfigForModelsOptions{pc: pc, models: opts.models})
	} else {
		pc = normalizeProjectConfig(pc)
	}
	data, err := json.MarshalIndent(pc, "", "  ")
	if err != nil {
		return fmt.Errorf("marshaling project config: %w", err)
	}
	return os.WriteFile(projectConfigPath(repoRoot), data, 0o644)
}
