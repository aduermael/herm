// configeditor_routing.go renders routing policy summaries and manages the
// external JSON editor used for advanced global routing configuration.
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"reflect"
	"sort"
	"strings"

	"golang.org/x/term"
)

const (
	routingJSONPreviewMaxLines = 64
	routingDiagnosticsMaxRows  = 4
)

func (a *App) routingTabReadOnlyRows() []string {
	return routingSummaryRows(a.cfgDraft.Routing)
}

func routingSummaryRows(policy *RoutingPolicy) []string {
	return []string{"Set custom routing, per provider or model (advanced)."}
}

func sortedRoutingStageKeys(values map[string][]RoutingStage) []string {
	if len(values) == 0 {
		return nil
	}
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

func routingStagesSummary(stages []RoutingStage) string {
	if len(stages) == 0 {
		return "no stages"
	}
	parts := make([]string, 0, len(stages))
	for i, stage := range stages {
		parts = append(parts, fmt.Sprintf("stage %d tries %s, retries %d", i+1, routingChoicesSummary(stage.Deployments), stage.Retries))
	}
	return strings.Join(parts, "; ")
}

func routingScopedStagesSummary(stages []RoutingStage) string {
	if len(stages) == 0 {
		return "no deployments"
	}
	parts := make([]string, 0, len(stages))
	for i, stage := range stages {
		prefix := "primary"
		if i > 0 {
			prefix = "fallback"
		}
		part := fmt.Sprintf("%s %s", prefix, routingChoicesSummary(stage.Deployments))
		if stage.Retries > 0 {
			part += fmt.Sprintf(", retries %d", stage.Retries)
		}
		parts = append(parts, part)
	}
	return strings.Join(parts, "; ")
}

func routingChoicesSummary(choices []DeploymentChoice) string {
	if len(choices) == 0 {
		return "no deployments"
	}
	parts := make([]string, 0, len(choices))
	for _, choice := range choices {
		if choice.DeploymentID == "" {
			continue
		}
		weight := choice.Weight
		if weight == 0 {
			weight = 100
		}
		parts = append(parts, fmt.Sprintf("%s (weight %d)", choice.DeploymentID, weight))
	}
	return joinEnglishList(parts)
}

func joinEnglishList(parts []string) string {
	switch len(parts) {
	case 0:
		return "no deployments"
	case 1:
		return parts[0]
	case 2:
		return parts[0] + " and " + parts[1]
	default:
		return strings.Join(parts[:len(parts)-1], ", ") + ", and " + parts[len(parts)-1]
	}
}

type routingAddRuleDraft struct {
	scope      routingScope
	key        string
	primary    string
	fallback   string
	prettyName string
}

func (a *App) openRoutingAddRuleScopeMenu() {
	var lines []string
	var actions []func()
	if len(routingProviderCandidates(routingProviderCandidatesOptions{cfg: a.cfgDraft, models: a.models})) > 0 {
		lines = append(lines, "Provider rule")
		actions = append(actions, a.openRoutingProviderRuleMenu)
	}
	if len(routingModelCandidates(routingModelCandidatesOptions{cfg: a.cfgDraft, models: a.models})) > 0 {
		lines = append(lines, "Model rule")
		actions = append(actions, a.openRoutingModelRuleMenu)
	}
	if len(lines) == 0 {
		a.messages = append(a.messages, chatMessage{kind: msgError, content: "No new routing scopes are available."})
		return
	}
	a.openConfigActionMenu(openConfigActionMenuOptions{
		header: "Add routing rule",
		lines:  lines,
		onSelect: func(idx int) {
			if idx < 0 || idx >= len(actions) {
				return
			}
			actions[idx]()
		},
	})
}

func (a *App) openRoutingProviderRuleMenu() {
	providers := routingProviderCandidates(routingProviderCandidatesOptions{cfg: a.cfgDraft, models: a.models})
	if len(providers) == 0 {
		a.messages = append(a.messages, chatMessage{kind: msgError, content: "No provider routing scopes are available."})
		return
	}
	a.openConfigActionMenu(openConfigActionMenuOptions{
		header: "Choose provider scope",
		lines:  providers,
		onSelect: func(idx int) {
			if idx < 0 || idx >= len(providers) {
				return
			}
			providerID := providers[idx]
			a.openRoutingPrimaryDeploymentMenu(routingAddRuleDraft{scope: routingScopeProvider, key: providerID, prettyName: "Provider " + providerID})
		},
	})
}

func (a *App) openRoutingModelRuleMenu() {
	models := routingModelCandidates(routingModelCandidatesOptions{cfg: a.cfgDraft, models: a.models})
	if len(models) == 0 {
		a.messages = append(a.messages, chatMessage{kind: msgError, content: "No model routing scopes are available."})
		return
	}
	lines := make([]string, 0, len(models))
	for _, model := range models {
		lines = append(lines, model.ID)
	}
	a.openConfigActionMenu(openConfigActionMenuOptions{
		header: "Choose model scope",
		lines:  lines,
		onSelect: func(idx int) {
			if idx < 0 || idx >= len(models) {
				return
			}
			modelID := models[idx].ID
			a.openRoutingPrimaryDeploymentMenu(routingAddRuleDraft{scope: routingScopeModel, key: modelID, prettyName: "Model " + modelID})
		},
	})
}

func (a *App) openRoutingPrimaryDeploymentMenu(draft routingAddRuleDraft) {
	deployments := routingEligibleDeploymentCandidates(routingEligibleDeploymentCandidatesOptions{cfg: a.cfgDraft, models: a.models, draft: draft})
	if len(deployments) == 0 {
		a.messages = append(a.messages, chatMessage{kind: msgError, content: "No eligible deployments are available for this routing rule."})
		return
	}
	a.openConfigActionMenu(openConfigActionMenuOptions{
		header: "Choose primary deployment for " + draft.prettyName,
		lines:  deployments,
		onSelect: func(idx int) {
			if idx < 0 || idx >= len(deployments) {
				return
			}
			next := draft
			next.primary = deployments[idx]
			a.openRoutingFallbackDeploymentMenu(next)
		},
	})
}

func (a *App) openRoutingFallbackDeploymentMenu(draft routingAddRuleDraft) {
	deployments := routingEligibleDeploymentCandidates(routingEligibleDeploymentCandidatesOptions{cfg: a.cfgDraft, models: a.models, draft: draft})
	lines := []string{"No fallback"}
	for _, deploymentID := range deployments {
		if deploymentID != draft.primary {
			lines = append(lines, deploymentID)
		}
	}
	a.openConfigActionMenu(openConfigActionMenuOptions{
		header: "Choose optional fallback for " + draft.prettyName,
		lines:  lines,
		onSelect: func(idx int) {
			next := draft
			if idx > 0 && idx < len(lines) {
				next.fallback = lines[idx]
			}
			a.openRoutingReviewRuleMenu(next)
		},
	})
}

func (a *App) openRoutingReviewRuleMenu(draft routingAddRuleDraft) {
	line := fmt.Sprintf("Save %s: primary %s", draft.prettyName, draft.primary)
	if draft.fallback != "" {
		line += "; fallback " + draft.fallback
	}
	a.openConfigActionMenu(openConfigActionMenuOptions{
		header: "Review routing rule",
		lines:  []string{line, "Cancel"},
		onSelect: func(idx int) {
			if idx != 0 {
				return
			}
			saveRoutingRule(saveRoutingRuleOptions{cfg: &a.cfgDraft, draft: draft})
			a.messages = append(a.messages, chatMessage{kind: msgSuccess, content: "Routing rule saved."})
		},
	})
}

func (a *App) openRoutingDeleteRuleMenu() {
	rules := routingRuleMenuItems(a.cfgDraft.Routing)
	if len(rules) == 0 {
		a.messages = append(a.messages, chatMessage{kind: msgError, content: "No scoped routing rules to delete."})
		return
	}
	lines := make([]string, 0, len(rules))
	for _, rule := range rules {
		lines = append(lines, rule.label)
	}
	a.openConfigActionMenu(openConfigActionMenuOptions{
		header: "Delete routing rule",
		lines:  lines,
		onSelect: func(idx int) {
			if idx < 0 || idx >= len(rules) {
				return
			}
			deleteRoutingRule(deleteRoutingRuleOptions{cfg: &a.cfgDraft, item: rules[idx]})
			a.clampConfigCursor()
			a.messages = append(a.messages, chatMessage{kind: msgSuccess, content: "Routing rule deleted."})
		},
	})
}

func (a *App) openRoutingRuleOptionsMenu(item routingRuleMenuItem) {
	a.openConfigActionMenu(openConfigActionMenuOptions{
		header: item.label,
		lines:  []string{"Replace rule", "Delete rule", "Cancel"},
		onSelect: func(idx int) {
			switch idx {
			case 0:
				a.openRoutingPrimaryDeploymentMenu(routingAddRuleDraft{scope: item.scope, key: item.key, prettyName: item.label})
			case 1:
				deleteRoutingRule(deleteRoutingRuleOptions{cfg: &a.cfgDraft, item: item})
				a.clampConfigCursor()
				a.messages = append(a.messages, chatMessage{kind: msgSuccess, content: "Routing rule deleted."})
			}
		},
	})
}

type routingRuleMenuItem struct {
	label string
	scope routingScope
	key   string
}

func routingRuleMenuItems(policy *RoutingPolicy) []routingRuleMenuItem {
	if policy == nil {
		return nil
	}
	var items []routingRuleMenuItem
	for _, providerID := range sortedRoutingStageKeys(policy.Providers) {
		items = append(items, routingRuleMenuItem{label: "Provider " + providerID, scope: routingScopeProvider, key: providerID})
	}
	for _, modelID := range sortedRoutingStageKeys(policy.Models) {
		items = append(items, routingRuleMenuItem{label: "Model " + modelID, scope: routingScopeModel, key: modelID})
	}
	return items
}

type saveRoutingRuleOptions struct {
	cfg   *Config
	draft routingAddRuleDraft
}

func saveRoutingRule(opts saveRoutingRuleOptions) {
	cfg, draft := opts.cfg, opts.draft
	stages := []RoutingStage{{
		Deployments: []DeploymentChoice{{DeploymentID: draft.primary, Weight: 100}},
	}}
	if draft.fallback != "" {
		stages = append(stages, RoutingStage{Deployments: []DeploymentChoice{{DeploymentID: draft.fallback, Weight: 100}}})
	}
	setRoutingStages(setRoutingStagesOptions{cfg: cfg, scope: draft.scope, key: draft.key, stages: stages})
}

type deleteRoutingRuleOptions struct {
	cfg  *Config
	item routingRuleMenuItem
}

func deleteRoutingRule(opts deleteRoutingRuleOptions) {
	cfg, item := opts.cfg, opts.item
	setRoutingStages(setRoutingStagesOptions{cfg: cfg, scope: item.scope, key: item.key, stages: nil})
}

type routingProviderCandidatesOptions struct {
	cfg    Config
	models []ModelDef
}

func routingProviderCandidates(opts routingProviderCandidatesOptions) []string {
	existingPolicy := opts.cfg.Routing
	cfg := opts.cfg
	cfg.Routing = nil
	models := cfg.availableModels(opts.models)
	seen := map[string]bool{}
	for _, model := range models {
		providerID := model.OwnerProvider
		if providerID == "" {
			providerID = model.Provider
		}
		providerID = canonicalProviderID(providerID)
		if providerID != "" {
			seen[providerID] = true
		}
	}
	out := make([]string, 0, len(seen))
	for providerID := range seen {
		if existingPolicy != nil {
			if _, ok := existingPolicy.Providers[providerID]; ok {
				continue
			}
		}
		deployments := routingEligibleDeploymentCandidates(routingEligibleDeploymentCandidatesOptions{
			cfg:    opts.cfg,
			models: opts.models,
			draft:  routingAddRuleDraft{scope: routingScopeProvider, key: providerID},
		})
		if len(deployments) == 0 {
			continue
		}
		out = append(out, providerID)
	}
	sort.Strings(out)
	return out
}

type routingModelCandidatesOptions struct {
	cfg    Config
	models []ModelDef
}

func routingModelCandidates(opts routingModelCandidatesOptions) []ModelDef {
	existingPolicy := opts.cfg.Routing
	cfg := opts.cfg
	cfg.Routing = nil
	models := cfg.availableModels(opts.models)
	if existingPolicy != nil && len(existingPolicy.Models) > 0 {
		filtered := models[:0]
		for _, model := range models {
			if _, ok := existingPolicy.Models[model.ID]; ok {
				continue
			}
			filtered = append(filtered, model)
		}
		models = filtered
	}
	sort.SliceStable(models, func(i, j int) bool { return models[i].ID < models[j].ID })
	return models
}

type routingEligibleDeploymentCandidatesOptions struct {
	cfg    Config
	models []ModelDef
	draft  routingAddRuleDraft
}

func routingEligibleDeploymentCandidates(opts routingEligibleDeploymentCandidatesOptions) []string {
	cfg := opts.cfg
	cfg.Routing = nil
	models := cfg.availableModels(opts.models)
	seen := map[string]bool{}
	var providerCommon map[string]bool
	providerMatched := false
	for _, model := range models {
		switch opts.draft.scope {
		case routingScopeProvider:
			providerID := model.OwnerProvider
			if providerID == "" {
				providerID = model.Provider
			}
			if canonicalProviderID(providerID) != canonicalProviderID(opts.draft.key) {
				continue
			}
			modelDeployments := map[string]bool{}
			for _, deployment := range model.Deployments {
				if deployment.DeploymentID != "" {
					modelDeployments[deployment.DeploymentID] = true
				}
			}
			if !providerMatched {
				providerCommon = modelDeployments
				providerMatched = true
			} else {
				for deploymentID := range providerCommon {
					if !modelDeployments[deploymentID] {
						delete(providerCommon, deploymentID)
					}
				}
			}
			continue
		case routingScopeModel:
			if model.ID != opts.draft.key {
				continue
			}
		default:
			continue
		}
		for _, deployment := range model.Deployments {
			if deployment.DeploymentID != "" {
				seen[deployment.DeploymentID] = true
			}
		}
	}
	if opts.draft.scope == routingScopeProvider {
		for deploymentID := range providerCommon {
			seen[deploymentID] = true
		}
	}
	out := make([]string, 0, len(seen))
	for deploymentID := range seen {
		out = append(out, deploymentID)
	}
	sort.Strings(out)
	return out
}

type openConfigActionMenuOptions struct {
	header   string
	lines    []string
	onSelect func(int)
}

func (a *App) openConfigActionMenu(opts openConfigActionMenuOptions) {
	if len(opts.lines) == 0 {
		return
	}
	a.menuHeader = opts.header
	a.menuLines = append([]string(nil), opts.lines...)
	a.menuCursor = 0
	a.menuScrollOffset = 0
	a.menuModels = nil
	a.menuActiveID = ""
	a.menuActive = true
	a.menuAction = func(idx int) {
		a.menuLines = nil
		a.menuHeader = ""
		a.menuActive = false
		a.menuAction = nil
		a.menuScrollOffset = 0
		a.menuModels = nil
		a.menuActiveID = ""
		if opts.onSelect != nil {
			opts.onSelect(idx)
		}
	}
	a.renderInput()
}

// routingJSONPreviewRowsOptions is the parameter bundle for routingJSONPreviewRows.
type routingJSONPreviewRowsOptions struct {
	policy   *RoutingPolicy
	maxLines int
}

func routingJSONPreviewRows(opts routingJSONPreviewRowsOptions) []string {
	policy, maxLines := opts.policy, opts.maxLines
	data, err := json.MarshalIndent(routingPolicyPreviewValue(policy), "", "  ")
	if err != nil {
		return []string{fmt.Sprintf("(routing JSON unavailable: %v)", err)}
	}
	lines := strings.Split(string(data), "\n")
	if maxLines <= 0 || len(lines) <= maxLines {
		return lines
	}
	visible := append([]string{}, lines[:maxLines-1]...)
	remaining := len(lines) - len(visible)
	visible = append(visible, fmt.Sprintf("... (%d more routing JSON lines)", remaining))
	return visible
}

func routingPolicyPreviewValue(policy *RoutingPolicy) RoutingPolicy {
	if policy == nil {
		return RoutingPolicy{}
	}
	clone := cloneRoutingPolicy(policy)
	if clone == nil {
		return RoutingPolicy{}
	}
	return *clone
}

func (a *App) openRoutingGlobalConfigEditor() {
	if a.hasUnsavedConfigDrafts() {
		a.messages = append(a.messages, chatMessage{kind: msgError, content: "Save or discard current config edits before editing global JSON."})
		return
	}
	if err := ensureGlobalConfigFileExists(a.globalConfig); err != nil {
		a.messages = append(a.messages, chatMessage{kind: msgError, content: fmt.Sprintf("Error preparing global config JSON: %v", err)})
		return
	}
	path := configPath()
	if err := a.runConfigJSONEditor(path); err != nil {
		a.messages = append(a.messages, chatMessage{kind: msgError, content: fmt.Sprintf("Global config JSON editor failed: %v", err)})
		return
	}
	cfg, err := loadConfigFileStrict(path)
	if err != nil {
		a.messages = append(a.messages, chatMessage{kind: msgError, content: fmt.Sprintf("Global config JSON is invalid; keeping current draft in memory: %v", err)})
		return
	}
	a.globalConfig = cfg
	a.cfgDraft = cfg
	a.cfgProjectDraft = a.projectConfig
	a.rebuildEffectiveConfig()
	a.messages = append(a.messages, chatMessage{kind: msgSuccess, content: "Global config JSON reloaded."})
}

func (a *App) hasUnsavedConfigDrafts() bool {
	globalDraft := deploymentAwareConfigFromLegacyConfig(a.cfgDraft)
	globalSaved := deploymentAwareConfigFromLegacyConfig(a.globalConfig)
	return !reflect.DeepEqual(globalDraft, globalSaved) || !reflect.DeepEqual(a.cfgProjectDraft, a.projectConfig)
}

func ensureGlobalConfigFileExists(cfg Config) error {
	if err := ensureConfigDir(); err != nil {
		return err
	}
	if _, err := os.Stat(configPath()); err == nil {
		return nil
	} else if !os.IsNotExist(err) {
		return err
	}
	return saveConfig(cfg)
}

func (a *App) runConfigJSONEditor(path string) error {
	if a.configJSONEditor != nil {
		return a.configJSONEditor(path)
	}

	a.stopStdinReader()
	fmt.Print("\033[?25h")
	fmt.Print("\033[>4;0m")
	fmt.Print("\033[?2004l")
	if a.oldState != nil {
		_ = term.Restore(a.fd, a.oldState)
	}

	err := defaultConfigJSONEditor(path)

	if a.oldState != nil {
		if _, rawErr := term.MakeRaw(a.fd); rawErr != nil && err == nil {
			err = rawErr
		}
	}
	flushStdin(a.fd)
	fmt.Print("\033[?2004h")
	fmt.Print("\033[>4;2m")
	a.startStdinReader()
	a.width = getWidth()
	return err
}

func defaultConfigJSONEditor(path string) error {
	editor := strings.TrimSpace(os.Getenv("VISUAL"))
	if editor == "" {
		editor = strings.TrimSpace(os.Getenv("EDITOR"))
	}
	if editor == "" {
		editor = "vi"
	}
	args := strings.Fields(editor)
	if len(args) == 0 {
		args = []string{"vi"}
	}
	cmd := exec.Command(args[0], append(args[1:], path)...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func loadConfigFileStrict(path string) (Config, error) {
	cfg := defaultConfig()
	data, err := os.ReadFile(path)
	if err != nil {
		return cfg, err
	}
	if err := json.Unmarshal(data, &cfg); err != nil {
		return cfg, err
	}
	return normalizeLoadedConfig(cfg), nil
}
