// configeditor.go implements the interactive config editor UI, including
// tab navigation, field editing, model picker integration, and key handling.
package main

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"langdag.com/langdag/types"
)

// isOllamaOffline reports whether modelID is an Ollama model that is not
// present in the current live model list (i.e. Ollama is configured but down).
// Returns false if no Ollama URL is configured.
func (a *App) isOllamaOffline(modelID string) bool {
	if modelID == "" {
		return false
	}
	// Check if it's in the live list as an Ollama model.
	for _, m := range a.models {
		if modelMatchesID(modelMatchesIDOptions{model: m, id: modelID}) && m.Provider == ProviderOllama {
			return false // online and present
		}
	}
	// Not in live list — treat as offline if it's not a known catalog model either.
	for _, m := range a.models {
		if modelMatchesID(modelMatchesIDOptions{model: m, id: modelID}) {
			return false // it's a different provider's model
		}
	}
	return true // unknown to catalog → assume offline Ollama model
}

// ─── Config editor ───

const (
	cfgTabDeployments = iota
	cfgTabGlobal
	cfgTabProject
	cfgTabRouting
	cfgTabCount
)

var cfgTabNames = []string{
	cfgTabDeployments: "Deployments",
	cfgTabGlobal:      "Global",
	cfgTabProject:     "Project",
	cfgTabRouting:     "Routing",
}

type cfgField struct {
	label      string
	indent     int
	get        func(Config) string
	display    func(Config) string // masked display; nil means use get
	set        func(*Config, string)
	toggle     func(*Config)       // if non-nil, Enter toggles instead of opening editor
	action     func(*App)          // if non-nil, Enter invokes an action instead of editing
	valueless  bool                // if true, render as a selectable row without ": value"
	optional   bool                // if true, empty values render as "(optional)"
	secret     bool                // if true, render displayed values with secret emphasis
	globalHint func(Config) string // if set, shows "(global: X)" when field value is empty
	picker     func(*App)          // if non-nil, Enter opens a picker (e.g. model selector) instead of editor
}

// effectiveProviderForConfig returns the provider implied by the effective
// active model. Falls back to the default configured provider when no active
// model can be resolved.
func (a *App) effectiveProviderForConfig(cfg Config) (provider string, modelID string) {
	modelID = cfg.resolveActiveModel(a.models)
	if modelID != "" {
		if model := findModelByID(findModelByIDOptions{models: a.models, id: modelID}); model != nil {
			return configuredProviderForModel(configuredProviderForModelOptions{cfg: cfg, model: *model}), modelID
		}
		// For unknown model IDs, keep the existing offline-Ollama assumption.
		return configuredProviderForModelID(configuredProviderForModelIDOptions{
			cfg:     cfg,
			models:  a.models,
			modelID: modelID,
		}), modelID
	}
	return cfg.defaultLangdagProviderForModels(a.models), ""
}

// preferredAPIKeyCursor chooses the initial cursor row in the API Keys tab:
// 1) active model provider, 2) first configured provider, 3) Anthropic.
func (a *App) preferredAPIKeyCursor(cfg Config) int {
	if p, _ := a.effectiveProviderForConfig(cfg); p != "" {
		return apiKeyRowForProviderInFields(apiKeyRowForProviderInFieldsOptions{provider: p, fields: deploymentTabFields(cfg)})
	}
	ordered := []string{ProviderAnthropic, ProviderOpenAI, ProviderGrok, ProviderOpenRouter, ProviderGemini, ProviderOllama, ProviderApple}
	configured := cfg.configuredProviders()
	for _, p := range ordered {
		if configured[p] {
			return apiKeyRowForProviderInFields(apiKeyRowForProviderInFieldsOptions{provider: p, fields: deploymentTabFields(cfg)})
		}
	}
	return 0
}

func (a *App) enterConfigMode() {
	a.cfgActive = true
	a.cfgTab = cfgTabDeployments
	a.cfgTabCursor = [cfgTabCount]int{cfgTabDeployments: a.preferredAPIKeyCursor(a.config)}
	a.cfgCursor = a.cfgTabCursor[a.cfgTab]
	a.cfgEditing = false
	a.cfgEditBuf = nil
	a.cfgEditCursor = 0
	a.cfgDraft = a.globalConfig
	a.cfgProjectDraft = a.projectConfig
	a.startConfigTicker()
	a.renderInput()
}

func (a *App) projectConfigRoot() string {
	if projectConfigScopeAvailable(a.repoRoot) {
		return a.repoRoot
	}
	return ""
}

func (a *App) exitConfigMode(save bool) {
	a.stopConfigTicker()
	if save {
		a.globalConfig = normalizeConfigForModels(configModelsOptions{cfg: a.cfgDraft, models: a.models})
		a.cfgDraft = a.globalConfig
		a.projectConfig = normalizeProjectConfigForModels(normalizeProjectConfigForModelsOptions{pc: a.cfgProjectDraft, models: a.models})
		a.cfgProjectDraft = a.projectConfig
		a.rebuildEffectiveConfig()
		// Re-initialize debug log if debug mode changed
		if a.debugActive() && a.traceCollector == nil {
			a.initAppDebugLog()
		} else if !a.debugActive() && a.traceCollector != nil {
			a.traceCollector.Finalize()
			if err := a.traceCollector.FlushToFile(a.traceFilePath); err != nil {
				fmt.Fprintf(os.Stderr, "debug: failed to write trace: %v\n", err)
			}
			a.traceCollector = nil
			a.traceFilePath = ""
		}
		var saveErr bool
		if err := saveConfig(a.globalConfig); err != nil {
			a.messages = append(a.messages, chatMessage{kind: msgError, content: fmt.Sprintf("Error saving global config: %v", err)})
			saveErr = true
		}
		if projectRoot := a.projectConfigRoot(); projectRoot != "" {
			if err := saveProjectConfig(saveProjectConfigOptions{repoRoot: projectRoot, pc: a.projectConfig, models: a.models}); err != nil {
				a.messages = append(a.messages, chatMessage{kind: msgError, content: fmt.Sprintf("Error saving project config: %v", err)})
				saveErr = true
			}
		}
		if !saveErr {
			a.messages = append(a.messages, chatMessage{kind: msgSuccess, content: "Config saved."})
		}
		// Refresh models including Ollama and OpenRouter if configured
		if a.config.ollamaBaseURL() != "" {
			go func() { a.resultCh <- fetchOllamaModelsCmd(a.config.ollamaBaseURL()) }()
		}
		if a.config.openRouterAPIKey() != "" {
			a.openRouterFetched = false // allow re-fetch with new key
			go func() { a.resultCh <- fetchOpenRouterModelsCmd(a.config.openRouterAPIKey()) }()
		}
		a.appleFetched = false
		go func() { a.resultCh <- fetchAppleModelsCmd(a.config.appleFMBaseURL()) }()
		// Show updated model resolution and project diagnostics.
		if a.models != nil {
			a.refreshResolvedModelDisplay()
		}
		// Reinitialize langdag client with updated config
		cfg := a.config
		models := a.models
		catalog := a.modelCatalog
		provider := cfg.defaultLangdagProviderForModels(models)
		go func() {
			client, err := newLangdagClientForModelsWithCatalog(newLangdagClientForModelsWithCatalogOptions{
				cfg:     cfg,
				models:  models,
				catalog: catalog,
			})
			a.resultCh <- langdagReadyMsg{client: client, provider: provider, runtimeApple: hasRuntimeAppleModels(models), err: err}
		}()
	}
	a.cfgActive = false
	a.cfgEditing = false
	a.cfgEditBuf = nil
	a.render()
}

// openConfigModelPickerOptions is the parameter bundle for openConfigModelPicker.
type openConfigModelPickerOptions struct {
	getCurrentID func() string
	onSelect     func(string)
}

// openConfigModelPicker opens an inline model menu within the config editor.
// getCurrentID returns the currently selected model ID (for highlighting).
// onSelect is called with the chosen model ID when the user makes a selection.
// If the draft Ollama URL differs from the saved URL, models are fetched
// asynchronously and the picker opens once results arrive.
func (a *App) openConfigModelPicker(opts openConfigModelPickerOptions) {
	getCurrentID, onSelect := opts.getCurrentID, opts.onSelect
	if a.models == nil {
		return
	}
	// If the draft URL differs from the saved URL, fetch Ollama models async
	// before opening the picker so we don't block the UI.
	if a.cfgDraft.ollamaBaseURL() != "" && a.config.ollamaBaseURL() != a.cfgDraft.ollamaBaseURL() {
		go func() {
			msg := fetchOllamaModelsCmd(a.cfgDraft.ollamaBaseURL())
			a.resultCh <- msg
			// Open the picker after the result is handled; send a follow-up
			// signal via a dedicated picker-open message.
			a.resultCh <- openPickerMsg{getCurrentID: getCurrentID, onSelect: onSelect}
		}()
		return
	}
	// If the draft OpenRouter key differs from the saved key, fetch fresh models
	// async before opening the picker.
	if a.cfgDraft.openRouterAPIKey() != "" && a.config.openRouterAPIKey() != a.cfgDraft.openRouterAPIKey() {
		go func() {
			msg := fetchOpenRouterModelsCmd(a.cfgDraft.openRouterAPIKey())
			a.resultCh <- msg
			a.resultCh <- openPickerMsg{getCurrentID: getCurrentID, onSelect: onSelect}
		}()
		return
	}
	// If the draft Apple FM URL differs from the saved URL, refresh dynamic
	// Apple models before showing available choices.
	if a.config.appleFMBaseURL() != a.cfgDraft.appleFMBaseURL() {
		go func() {
			a.resultCh <- fetchDraftAppleModelsCmd(fetchDraftAppleModelsCmdOptions{
				baseURL:      a.cfgDraft.appleFMBaseURL(),
				getCurrentID: getCurrentID,
				onSelect:     onSelect,
			})
		}()
		return
	}
	a.doOpenConfigModelPicker(doOpenConfigModelPickerOptions{models: a.models, getCurrentID: getCurrentID, onSelect: onSelect})
}

// doOpenConfigModelPickerOptions is the parameter bundle for doOpenConfigModelPicker.
type doOpenConfigModelPickerOptions struct {
	models       []ModelDef
	getCurrentID func() string
	onSelect     func(string)
}

// doOpenConfigModelPicker builds and displays the model picker menu.
func (a *App) doOpenConfigModelPicker(opts doOpenConfigModelPickerOptions) {
	models, getCurrentID, onSelect := opts.models, opts.getCurrentID, opts.onSelect
	available := a.cfgDraft.availableModels(models)

	// If Ollama is configured but offline, inject a stub for the saved model
	// so the picker still opens and the user can see their current selection.
	if a.cfgDraft.ollamaBaseURL() != "" {
		ollamaInList := false
		for _, m := range available {
			if m.Provider == ProviderOllama {
				ollamaInList = true
				break
			}
		}
		if !ollamaInList {
			savedID := getCurrentID()
			if savedID == "" {
				savedID = a.cfgDraft.ActiveModel
			}
			if savedID != "" {
				available = append(available, ModelDef{
					Provider: ProviderOllama,
					ID:       savedID,
					Label:    savedID + " \033[33m(offline)\033[0m",
				})
			}
		}
	}

	// If OpenRouter is configured but models haven't loaded yet (e.g. bad key or
	// network error), inject a stub so the picker still shows the saved selection.
	if a.cfgDraft.openRouterAPIKey() != "" {
		savedID := getCurrentID()
		if savedID == "" {
			savedID = a.cfgDraft.ActiveModel
		}
		if savedID != "" && !modelListContainsID(modelListContainsIDOptions{models: available, id: savedID}) {
			available = append(available, ModelDef{
				Provider:      ProviderOpenRouter,
				ID:            savedID,
				Label:         savedID + " \033[33m(unavailable)\033[0m",
				PricingStatus: types.CostStatusUnknown,
				PriceLabel:    "unknown",
			})
		}
	}

	if len(available) == 0 {
		return
	}

	activeID := getCurrentID()
	a.menuModels = available
	a.menuActiveID = activeID
	a.menuSortCol = sortColFromName(a.cfgDraft.ModelSortCol)
	a.menuSortAsc = sortAscFromMap(a.cfgDraft.ModelSortDirs)
	asc := a.menuSortAsc[a.menuSortCol]
	sortModelsByCol(sortModelsByColOptions{models: a.menuModels, col: a.menuSortCol, asc: asc})
	header, lines := formatModelMenuLines(formatModelMenuLinesOptions{models: a.menuModels, activeID: activeID, sortCol: a.menuSortCol, sortAsc: asc})

	activeIdx := 0
	for i, m := range a.menuModels {
		if modelMatchesID(modelMatchesIDOptions{model: m, id: activeID}) {
			activeIdx = i
			break
		}
	}

	a.menuHeader = header
	a.menuLines = lines
	a.menuCursor = activeIdx
	maxVisible := getTerminalHeight() * 60 / 100
	if maxVisible < 1 {
		maxVisible = 1
	}
	if activeIdx >= maxVisible {
		a.menuScrollOffset = activeIdx - maxVisible + 1
	} else {
		a.menuScrollOffset = 0
	}
	a.menuActive = true
	a.menuAction = func(idx int) {
		if idx >= 0 && idx < len(a.menuModels) {
			onSelect(a.menuModels[idx].ID)
		}
		a.menuLines = nil
		a.menuHeader = ""
		a.menuActive = false
		a.menuAction = nil
		a.menuScrollOffset = 0
		a.menuModels = nil
		a.menuActiveID = ""
		// Config mode stays active — renderInput will show config fields again.
	}
	a.renderInput()
}

func (a *App) cfgCurrentFields() []cfgField {
	switch a.cfgTab {
	case cfgTabDeployments:
		return deploymentTabFields(a.cfgDraft)
	case cfgTabGlobal:
		return a.settingsTabFields()
	case cfgTabProject:
		if a.projectConfigRoot() == "" {
			return nil
		}
		return a.projectTabFields()
	case cfgTabRouting:
		return a.routingTabFields()
	}
	return nil
}

func (a *App) clampConfigCursor() {
	fields := a.cfgCurrentFields()
	if len(fields) == 0 {
		a.cfgCursor = 0
		a.cfgTabCursor[a.cfgTab] = 0
		return
	}
	if a.cfgCursor < 0 {
		a.cfgCursor = 0
	} else if a.cfgCursor >= len(fields) {
		a.cfgCursor = len(fields) - 1
	}
	a.cfgTabCursor[a.cfgTab] = a.cfgCursor
}

func (a *App) configSelectedField() (cfgField, bool) {
	fields := a.cfgCurrentFields()
	if len(fields) == 0 || a.cfgCursor < 0 || a.cfgCursor >= len(fields) {
		return cfgField{}, false
	}
	return fields[a.cfgCursor], true
}

func (a *App) resolvedExplorationDisplay(c Config) string {
	if c.ExplorationModel != "" {
		return c.ExplorationModel
	}
	if len(c.configuredProviders()) == 0 {
		return ""
	}
	return c.resolveExplorationModel(a.models)
}

func (a *App) settingsTabFields() []cfgField {
	return []cfgField{
		{label: "Active Model", get: func(c Config) string { return c.ActiveModel }, set: func(c *Config, v string) {
			c.ActiveModel = normalizeConfigModelIDForModels(normalizeConfigModelIDForModelsOptions{cfg: *c, modelID: v, smartDefault: defaultCanonicalActiveModel, models: a.models})
		}, picker: func(a *App) {
			a.openConfigModelPicker(openConfigModelPickerOptions{getCurrentID: func() string { return a.cfgDraft.ActiveModel }, onSelect: func(id string) { a.cfgDraft.ActiveModel = id }})
		}},
		{label: "Exploration Model", get: func(c Config) string { return c.ExplorationModel }, display: func(c Config) string { return a.resolvedExplorationDisplay(c) }, set: func(c *Config, v string) {
			c.ExplorationModel = normalizeConfigModelIDForModels(normalizeConfigModelIDForModelsOptions{cfg: *c, modelID: v, smartDefault: defaultCanonicalExplorationModel, models: a.models})
		}, picker: func(a *App) {
			a.openConfigModelPicker(openConfigModelPickerOptions{getCurrentID: func() string { return a.cfgDraft.ExplorationModel }, onSelect: func(id string) { a.cfgDraft.ExplorationModel = id }})
		}},
		{label: "Paste Collapse", get: func(c Config) string { return strconv.Itoa(c.PasteCollapseMinChars) }, set: func(c *Config, v string) {
			if n, err := strconv.Atoi(v); err == nil {
				c.PasteCollapseMinChars = n
			}
		}},
		{label: "Debug Mode", get: func(c Config) string {
			if c.DebugMode {
				return "on"
			}
			return "off"
		}, toggle: func(c *Config) { c.DebugMode = !c.DebugMode }},
		{label: "Thinking", get: func(c Config) string {
			if c.effectiveThinking() {
				return "on"
			}
			return "off"
		}, toggle: func(c *Config) {
			if c.Thinking == nil {
				t := true
				c.Thinking = &t
			} else {
				v := !*c.Thinking
				c.Thinking = &v
			}
		}},
		{label: "Sub-Agent Max Turns", get: func(c Config) string {
			n := c.SubAgentMaxTurns
			if n <= 0 {
				n = defaultGeneralMaxTurns
			}
			return strconv.Itoa(n)
		}, set: func(c *Config, v string) {
			if n, err := strconv.Atoi(v); err == nil && n > 0 {
				c.SubAgentMaxTurns = n
			}
		}},
		{label: "Personality", get: func(c Config) string { return c.Personality }, set: func(c *Config, v string) { c.Personality = v }},
		{label: "Git Co-Author", get: func(c Config) string {
			if c.effectiveGitCoAuthor() {
				return "on"
			}
			return "off"
		}, toggle: func(c *Config) {
			if c.GitCoAuthor == nil {
				f := false
				c.GitCoAuthor = &f
			} else {
				v := !*c.GitCoAuthor
				c.GitCoAuthor = &v
			}
		}},
	}
}

func (a *App) projectTabFields() []cfgField {
	return []cfgField{
		{
			label: "Active Model",
			get:   func(_ Config) string { return a.cfgProjectDraft.ActiveModel },
			set: func(_ *Config, v string) {
				a.cfgProjectDraft.ActiveModel = normalizeProjectModelIDForModels(normalizeProjectModelIDForModelsOptions{modelID: v, smartDefault: defaultCanonicalActiveModel, models: a.models})
			},
			globalHint: func(c Config) string { return c.ActiveModel },
			picker: func(a *App) {
				a.openConfigModelPicker(openConfigModelPickerOptions{getCurrentID: func() string { return a.cfgProjectDraft.ActiveModel }, onSelect: func(id string) { a.cfgProjectDraft.ActiveModel = id }})
			},
		},
		{
			label: "Exploration Model",
			get:   func(_ Config) string { return a.cfgProjectDraft.ExplorationModel },
			set: func(_ *Config, v string) {
				a.cfgProjectDraft.ExplorationModel = normalizeProjectModelIDForModels(normalizeProjectModelIDForModelsOptions{modelID: v, smartDefault: defaultCanonicalExplorationModel, models: a.models})
			},
			globalHint: func(c Config) string { return a.resolvedExplorationDisplay(c) },
			picker: func(a *App) {
				a.openConfigModelPicker(openConfigModelPickerOptions{getCurrentID: func() string { return a.cfgProjectDraft.ExplorationModel }, onSelect: func(id string) { a.cfgProjectDraft.ExplorationModel = id }})
			},
		},
		{
			label:      "Personality",
			get:        func(_ Config) string { return a.cfgProjectDraft.Personality },
			set:        func(_ *Config, v string) { a.cfgProjectDraft.Personality = v },
			globalHint: func(c Config) string { return c.Personality },
		},
		{
			label: "Sub-Agent Max Turns",
			get: func(_ Config) string {
				if a.cfgProjectDraft.SubAgentMaxTurns == 0 {
					return ""
				}
				return strconv.Itoa(a.cfgProjectDraft.SubAgentMaxTurns)
			},
			set: func(_ *Config, v string) {
				if n, err := strconv.Atoi(v); err == nil && n > 0 {
					a.cfgProjectDraft.SubAgentMaxTurns = n
				} else {
					a.cfgProjectDraft.SubAgentMaxTurns = 0
				}
			},
			globalHint: func(c Config) string {
				n := c.SubAgentMaxTurns
				if n <= 0 {
					n = defaultGeneralMaxTurns
				}
				return strconv.Itoa(n)
			},
		},
		{
			label: "Thinking",
			get: func(_ Config) string {
				if a.cfgProjectDraft.Thinking == nil {
					return ""
				}
				if *a.cfgProjectDraft.Thinking {
					return "on"
				}
				return "off"
			},
			toggle: func(_ *Config) {
				if a.cfgProjectDraft.Thinking == nil {
					t := true
					a.cfgProjectDraft.Thinking = &t
				} else {
					v := !*a.cfgProjectDraft.Thinking
					a.cfgProjectDraft.Thinking = &v
				}
			},
			globalHint: func(c Config) string {
				if c.effectiveThinking() {
					return "on"
				}
				return "off"
			},
		},
	}
}

func (a *App) configRowsBeforeFields() int {
	switch a.cfgTab {
	case cfgTabProject:
		if a.projectConfigRoot() != "" {
			return 1
		}
	case cfgTabRouting:
		return len(a.routingTabReadOnlyRows())
	}
	return 0
}

func (a *App) buildConfigRows() []string {
	var rows []string
	configured := a.cfgDraft.configuredProviders()
	hasProvider := len(configured) > 0
	isProjectTab := a.cfgTab == cfgTabProject
	projectRoot := ""
	if isProjectTab {
		projectRoot = a.projectConfigRoot()
	}

	// Tab bar
	var tabParts []string
	for i, name := range cfgTabNames {
		if i == a.cfgTab {
			tabParts = append(tabParts, fmt.Sprintf("\033[36;1m[%s]\033[0m", name))
		} else {
			tabParts = append(tabParts, fmt.Sprintf("\033[2m %s \033[0m", name))
		}
	}
	rows = append(rows, strings.Join(tabParts, " "))

	if isProjectTab {
		if projectRoot == "" {
			rows = append(rows, "\033[2mNo project detected (not in a git repository)\033[0m")
			rows = append(rows, a.configHelpRows()...)
			return rows
		}
		rows = append(rows, fmt.Sprintf("\033[2mOverriding global config for current project (%s).\033[0m", projectRoot))
	}

	// When a model picker menu is active, render it inline below the tab bar
	if a.menuActive && len(a.menuLines) > 0 {
		w := a.width
		if a.menuHeader != "" {
			rows = append(rows, fmt.Sprintf("\033[1m%s\033[0m", truncateWithEllipsis(truncateWithEllipsisOptions{s: a.menuHeader, maxLen: w})))
		}
		maxVisible := getTerminalHeight() * 60 / 100
		if maxVisible < 1 {
			maxVisible = 1
		}
		total := len(a.menuLines)
		end := a.menuScrollOffset + maxVisible
		if end > total {
			end = total
		}
		for i := a.menuScrollOffset; i < end; i++ {
			line := a.menuLines[i]
			if i == a.menuCursor {
				rows = append(rows, fmt.Sprintf("\033[36;1m%s ◆\033[0m", truncateWithEllipsis(truncateWithEllipsisOptions{s: line, maxLen: w - 2})))
			} else {
				rows = append(rows, truncateWithEllipsis(truncateWithEllipsisOptions{s: line, maxLen: w}))
			}
		}
		first := a.menuScrollOffset + 1
		last := end
		rows = append(rows, fmt.Sprintf("\033[2m(%d->%d / %d)\033[0m", first, last, total))
		if a.menuModels != nil {
			rows = append(rows, layoutDimInlineBlocks(w, "Enter=choose", "Esc=close")...)
		} else {
			rows = append(rows, layoutDimInlineBlocks(w, "↑/↓=select", "Enter=choose", "Esc=close")...)
		}
		return rows
	}

	if a.cfgTab == cfgTabRouting {
		rows = append(rows, a.routingTabReadOnlyRows()...)
	}

	// Fields
	fields := a.cfgCurrentFields()
	for i, f := range fields {
		label := configFieldLabel(f)
		if f.valueless {
			if i == a.cfgCursor {
				rows = append(rows, fmt.Sprintf("%s %s", styledConfigFieldLabel(styledConfigFieldLabelOptions{label: label, selected: true}), styledConfigCursor("◆")))
			} else {
				rows = append(rows, styledConfigFieldLabel(styledConfigFieldLabelOptions{label: label}))
			}
			continue
		}
		if a.cfgEditing && i == a.cfgCursor {
			editStr := string(a.cfgEditBuf)
			if f.secret {
				editStr = secretEditDisplay(editStr)
			}
			rows = append(rows, fmt.Sprintf("%s \033[1m%s\033[0m %s", styledConfigFieldLabel(styledConfigFieldLabelOptions{label: label + ":", selected: true}), editStr, styledConfigCursor("◆")))
		} else {
			val := ""
			if f.display != nil {
				val = f.display(a.cfgDraft)
			} else if f.get != nil {
				val = f.get(a.cfgDraft)
			}
			if f.picker != nil && val != "" {
				p := configuredProviderForModelID(configuredProviderForModelIDOptions{
					cfg:     a.cfgDraft,
					models:  a.models,
					modelID: val,
				})
				// Hide model values when no providers are configured, or when this
				// model's provider is not currently configured.
				if !isProjectTab && (!hasProvider || p == "" || !configured[p]) {
					val = ""
				}
			}
			// If the value is an Ollama model and Ollama is offline, show indicator.
			// Only applies to model picker fields, not API key or other fields.
			if val != "" && f.picker != nil && a.cfgDraft.ollamaBaseURL() != "" && a.isOllamaOffline(val) {
				val = val + " \033[33m(offline)\033[0m"
			}
			if val == "" {
				if f.picker != nil && !hasProvider && !isProjectTab {
					val = "(not set)"
				} else if f.optional {
					val = "(optional)"
				} else if f.globalHint != nil {
					hint := f.globalHint(a.cfgDraft)
					if f.picker != nil && !isProjectTab {
						p := configuredProviderForModelID(configuredProviderForModelIDOptions{
							cfg:     a.cfgDraft,
							models:  a.models,
							modelID: hint,
						})
						if hint == "" || p == "" || !configured[p] {
							hint = "not set"
						}
					}
					if hint == "" {
						hint = "not set"
					}
					val = fmt.Sprintf("\033[2m(global: %s)\033[0m", hint)
				} else {
					val = "(not set)"
				}
			}
			styledValue := styledConfigFieldValue(styledConfigFieldValueOptions{value: val, secret: f.secret})
			if i == a.cfgCursor {
				rows = append(rows, fmt.Sprintf("%s %s %s", styledConfigFieldLabel(styledConfigFieldLabelOptions{label: label + ":", selected: true}), styledValue, styledConfigCursor("◆")))
			} else {
				rows = append(rows, fmt.Sprintf("%s %s", styledConfigFieldLabel(styledConfigFieldLabelOptions{label: label + ":"}), styledValue))
			}
		}
	}

	if a.cfgTab == cfgTabRouting && a.cfgDraft.Routing != nil {
		diagnostics := routingDiagnosticsForConfigModels(configModelsOptions{cfg: a.cfgDraft, models: a.models})
		for i, diagnostic := range diagnostics {
			if i >= routingDiagnosticsMaxRows {
				rows = append(rows, fmt.Sprintf("\033[33m%d more routing diagnostics\033[0m", len(diagnostics)-i))
				break
			}
			rows = append(rows, fmt.Sprintf("\033[33m%s: %s\033[0m", diagnostic.Path, diagnostic.Message))
		}
	}

	rows = append(rows, a.configHelpRows()...)

	return rows
}

// handleConfigByteOptions is the parameter bundle for handleConfigByte.
type handleConfigByteOptions struct {
	ch       byte
	stdinCh  chan byte
	readByte func() (byte, bool)
}

func (a *App) handleConfigByte(opts handleConfigByteOptions) {
	ch, stdinCh, readByte := opts.ch, opts.stdinCh, opts.readByte
	if a.cfgEditing {
		a.handleConfigEditByte(handleConfigEditByteOptions{ch: ch, stdinCh: stdinCh, readByte: readByte})
		return
	}

	switch {
	case ch == '\033': // Escape sequence
		var b byte
		var ok bool
		select {
		case b, ok = <-stdinCh:
			if !ok {
				return
			}
		case <-time.After(50 * time.Millisecond):
			a.exitConfigMode(false)
			return
		}
		if b != '[' {
			a.exitConfigMode(false)
			return
		}
		seq, ok := readCSISequence(readByte)
		if !ok {
			return
		}
		a.handleConfigCSISequence(handleConfigCSISequenceOptions{seq: seq, readByte: readByte})

	case ch == '\r': // Enter - toggle, picker, or start editing current field
		if a.cfgTab == cfgTabProject && a.projectConfigRoot() == "" {
			break // Project tab non-editable without a repo
		}
		fields := a.cfgCurrentFields()
		if len(fields) > 0 && a.cfgCursor < len(fields) {
			f := fields[a.cfgCursor]
			if f.action != nil {
				f.action(a)
			} else if f.picker != nil {
				f.picker(a)
			} else if f.toggle != nil {
				f.toggle(&a.cfgDraft)
			} else if f.get != nil && f.set != nil {
				a.cfgEditing = true
				val := f.get(a.cfgDraft)
				a.cfgEditBuf = []rune(val)
				a.cfgEditCursor = len(a.cfgEditBuf)
			}
		}
		a.renderInput()

	case ch == 127 || ch == 0x08: // Backspace - clear current project field (unset → fall back to global)
		if a.cfgTab == cfgTabProject && a.projectConfigRoot() != "" {
			fields := a.cfgCurrentFields()
			if len(fields) > 0 && a.cfgCursor < len(fields) {
				f := fields[a.cfgCursor]
				if f.set != nil && f.get != nil && f.get(a.cfgDraft) != "" {
					f.set(&a.cfgDraft, "")
					a.renderInput()
				}
			}
		}

	case ch == 0x13: // Ctrl+S - save and close
		a.exitConfigMode(true)

	case ch == 3 || ch == 4: // Ctrl+C/D - exit without saving
		a.exitConfigMode(false)
	}
}

// handleConfigEditByteOptions is the parameter bundle for handleConfigEditByte.
type handleConfigEditByteOptions struct {
	ch       byte
	stdinCh  chan byte
	readByte func() (byte, bool)
}

func (a *App) handleConfigEditByte(opts handleConfigEditByteOptions) {
	ch, stdinCh, readByte := opts.ch, opts.stdinCh, opts.readByte
	switch {
	case ch == '\033': // Escape
		var b byte
		var ok bool
		select {
		case b, ok = <-stdinCh:
			if !ok {
				return
			}
		case <-time.After(50 * time.Millisecond):
			// Plain Escape - cancel edit
			a.cfgEditing = false
			a.cfgEditBuf = nil
			a.renderInput()
			return
		}
		if b != '[' {
			a.cfgEditing = false
			a.cfgEditBuf = nil
			a.renderInput()
			return
		}
		seq, ok := readCSISequence(readByte)
		if !ok {
			return
		}
		a.handleConfigEditCSISequence(handleConfigEditCSISequenceOptions{seq: seq, readByte: readByte})

	case ch == '\r': // Enter - confirm edit
		fields := a.cfgCurrentFields()
		if a.cfgCursor < len(fields) {
			fields[a.cfgCursor].set(&a.cfgDraft, string(a.cfgEditBuf))
		}
		a.cfgEditing = false
		a.cfgEditBuf = nil
		a.clampConfigCursor()
		a.renderInput()

	case ch == 127 || ch == 0x08: // Backspace
		fields := a.cfgCurrentFields()
		if a.cfgCursor < len(fields) && fields[a.cfgCursor].secret {
			a.cfgEditBuf = nil
			a.cfgEditCursor = 0
		} else if a.cfgEditCursor > 0 {
			a.cfgEditCursor--
			a.cfgEditBuf = append(a.cfgEditBuf[:a.cfgEditCursor], a.cfgEditBuf[a.cfgEditCursor+1:]...)
		}
		a.renderInput()

	case ch == 0x01: // Ctrl+A
		a.cfgEditCursor = 0
		a.renderInput()

	case ch == 0x05: // Ctrl+E
		a.cfgEditCursor = len(a.cfgEditBuf)
		a.renderInput()

	case ch == 0x15: // Ctrl+U - kill to start
		fields := a.cfgCurrentFields()
		if a.cfgCursor < len(fields) && fields[a.cfgCursor].secret {
			a.cfgEditBuf = nil
			a.cfgEditCursor = 0
		} else {
			a.cfgEditBuf = a.cfgEditBuf[a.cfgEditCursor:]
			a.cfgEditCursor = 0
		}
		a.renderInput()

	case ch == 0x0b: // Ctrl+K - kill to end
		fields := a.cfgCurrentFields()
		if a.cfgCursor < len(fields) && fields[a.cfgCursor].secret {
			a.cfgEditBuf = nil
			a.cfgEditCursor = 0
		} else {
			a.cfgEditBuf = a.cfgEditBuf[:a.cfgEditCursor]
		}
		a.renderInput()

	case ch == 0x17: // Ctrl+W - delete word backward
		fields := a.cfgCurrentFields()
		if a.cfgCursor < len(fields) && fields[a.cfgCursor].secret {
			a.cfgEditBuf = nil
			a.cfgEditCursor = 0
			a.renderInput()
		} else if a.cfgEditCursor > 0 {
			a.deleteConfigEditWordBackward()
			a.renderInput()
		}

	case ch >= 0x20: // Printable character
		r := rune(ch)
		if ch >= 0x80 {
			b := []byte{ch}
			n := utf8ByteLen(ch)
			for i := 1; i < n; i++ {
				next, ok := readByte()
				if !ok {
					return
				}
				b = append(b, next)
			}
			r, _ = utf8.DecodeRune(b)
		}
		a.insertConfigEditRune(r)
		a.renderInput()
	}
}
