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
	rows := routingSummaryRows(a.cfgDraft.Routing)
	rows = append(rows, "routing JSON")
	rows = append(rows, routingJSONPreviewRows(a.cfgDraft.Routing, routingJSONPreviewMaxLines)...)
	return rows
}

func routingSummaryRows(policy *RoutingPolicy) []string {
	rows := []string{
		"Routing is global.",
		"Most users do not need routing; configured deployments are enough unless you want a specific fallback policy.",
		"Model routes override provider routes; provider routes override the default route.",
		"Overrides do not cascade to default. Stages are tried in order; deployment choices are weighted and retries apply per stage.",
	}
	if routingPolicyIsEmpty(policy) {
		return append(rows, "No routing policy is configured. Herm uses eligible configured deployments automatically.")
	}
	if len(policy.Default) > 0 {
		rows = append(rows, "Default: "+routingStagesSummary(policy.Default)+".")
	}
	for _, providerID := range sortedRoutingStageKeys(policy.Providers) {
		rows = append(rows, fmt.Sprintf("Provider %s: %s.", providerID, routingStagesSummary(policy.Providers[providerID])))
	}
	for _, modelID := range sortedRoutingStageKeys(policy.Models) {
		rows = append(rows, fmt.Sprintf("Model %s: %s.", modelID, routingStagesSummary(policy.Models[modelID])))
	}
	return rows
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

func routingJSONPreviewRows(policy *RoutingPolicy, maxLines int) []string {
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
	a.config = mergeConfigs(mergeConfigsOptions{global: a.globalConfig, project: a.projectConfig})
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
