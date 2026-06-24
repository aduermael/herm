// agentui_model_display.go handles model status lines, diagnostics, and
// related chat messages in the agent UI.
package main

import (
	"fmt"
	"strings"
)

// showResolvedModelDisplay updates the latest model status line (startup/catalog refresh).
func (a *App) showResolvedModelDisplay() {
	a.refreshLatestModelDisplay()
}

// appendModelDisplayAfterConfigSave records a new model status line after save notices
// without removing earlier Using lines from chat history.
func (a *App) appendModelDisplayAfterConfigSave(insertAt int) {
	msg, displayID, ok := a.buildModelDisplayMessage()
	if !ok {
		a.clearModelDisplayLine()
		return
	}
	if msg.content == a.lastModelDisplayLine {
		return
	}
	if insertAt < 0 || insertAt > len(a.messages) {
		insertAt = len(a.messages)
	}
	a.messages = append(a.messages[:insertAt], append([]chatMessage{msg}, a.messages[insertAt:]...)...)
	a.applyModelDisplaySideEffects(applyModelDisplaySideEffectsOptions{displayID: displayID, line: msg.content})
}

func (a *App) refreshLatestModelDisplay() {
	msg, displayID, ok := a.buildModelDisplayMessage()
	if !ok {
		a.clearModelDisplayLine()
		return
	}
	if msg.content == a.lastModelDisplayLine && a.hasModelDisplayMessage(msg.content) {
		return
	}
	for i := len(a.messages) - 1; i >= 0; i-- {
		if a.messages[i].modelDisplay {
			a.messages[i] = msg
			a.applyModelDisplaySideEffects(applyModelDisplaySideEffectsOptions{displayID: displayID, line: msg.content})
			return
		}
	}
	a.messages = append(a.messages, msg)
	a.applyModelDisplaySideEffects(applyModelDisplaySideEffectsOptions{displayID: displayID, line: msg.content})
}

func (a *App) buildModelDisplayMessage() (chatMessage, string, bool) {
	modelCfg := a.projectModelConfig()
	hasActive := explicitActiveModelConfigured(modelCfg)
	hasExploration := explicitExplorationModelConfigured(modelCfg)
	if !hasActive && !hasExploration {
		return chatMessage{}, "", false
	}

	var activeID, explorationID string
	var activeScope, explorationScope string
	if hasActive {
		activeID = explicitConfiguredActiveModelID(modelCfg)
		activeScope = activeModelConfigScope(modelCfg)
		if a.models != nil {
			result := a.config.resolveActiveModelResult(a.models)
			if id := displayConfiguredModelID(displayConfiguredModelIDOptions{
				result:     result,
				configured: explicitConfiguredActiveModelID(modelCfg),
			}); id != "" {
				activeID = id
			}
		}
	}
	if hasExploration {
		explorationID = explicitConfiguredExplorationModelID(modelCfg)
		explorationScope = explorationModelConfigScope(modelCfg)
		if a.models != nil {
			result := a.config.resolveExplorationModelResult(a.models)
			if id := displayConfiguredModelID(displayConfiguredModelIDOptions{
				result:     result,
				configured: explicitConfiguredExplorationModelID(modelCfg),
			}); id != "" {
				explorationID = id
			}
		}
	}
	if activeID == "" && hasActive {
		activeID = explicitConfiguredActiveModelID(modelCfg)
		activeScope = activeModelConfigScope(modelCfg)
	}
	if explorationID == "" && hasExploration {
		explorationID = explicitConfiguredExplorationModelID(modelCfg)
		explorationScope = explorationModelConfigScope(modelCfg)
	}
	if activeID == "" && explorationID == "" {
		return chatMessage{}, "", false
	}

	displayID := activeID
	if displayID == "" {
		displayID = explorationID
	}
	offline := a.ollamaFetched && a.config.ollamaBaseURL() != "" && a.isOllamaOffline(displayID)
	line, blocks := modelDisplayLine(modelDisplayLineOptions{
		activeID:         activeID,
		explorationID:    explorationID,
		activeScope:      activeScope,
		explorationScope: explorationScope,
		offline:          offline,
	})
	if line == "" {
		return chatMessage{}, "", false
	}
	return chatMessage{kind: msgInfo, content: line, inlineBlocks: blocks, modelDisplay: true}, displayID, true
}

type applyModelDisplaySideEffectsOptions struct {
	displayID string
	line      string
}

func (a *App) applyModelDisplaySideEffects(opts applyModelDisplaySideEffectsOptions) {
	offline := a.ollamaFetched && a.config.ollamaBaseURL() != "" && a.isOllamaOffline(opts.displayID)
	if offline {
		a.showOllamaOfflineNotice()
	} else {
		a.lastOllamaOfflineNotice = ""
	}
	a.lastModelID = opts.displayID
	a.lastModelDisplayLine = opts.line
}

func (a *App) clearModelDisplayLine() {
	a.lastModelDisplayLine = ""
	a.lastModelID = ""
}

func (a *App) hasModelDisplayMessage(content string) bool {
	for _, msg := range a.messages {
		if msg.modelDisplay && (content == "" || msg.content == content) {
			return true
		}
	}
	return false
}

type displayConfiguredModelIDOptions struct {
	result     configuredModelResolution
	configured string
}

func displayConfiguredModelID(opts displayConfiguredModelIDOptions) string {
	if opts.configured == "" {
		return ""
	}
	if !opts.result.Fallback && opts.result.ResolvedModelID != "" {
		return opts.result.ResolvedModelID
	}
	if opts.result.ConfiguredModelID != "" {
		return opts.result.ConfiguredModelID
	}
	return opts.configured
}

type modelDisplayLineOptions struct {
	activeID         string
	explorationID    string
	activeScope      string
	explorationScope string
	offline          bool
}

func modelDisplayLine(opts modelDisplayLineOptions) (string, []inlineBlock) {
	activeID, explorationID, offline := opts.activeID, opts.explorationID, opts.offline
	activeScopeSuffix := modelScopeSuffix(opts.activeScope)
	explorationScopeSuffix := modelScopeSuffix(opts.explorationScope)
	if activeID != "" {
		content := uiModelDisplayActivePrefix + activeID + activeScopeSuffix
		activeText := styleChatCyan + uiModelDisplayActivePrefix + activeID + styleChatMuted + activeScopeSuffix
		if offline {
			content += uiModelDisplayOffline
			activeText += " \033[33m(offline)"
		}
		blocks := []inlineBlock{newInlineBlock(activeText)}
		if explorationID != "" && explorationID != activeID {
			content += uiModelDisplayExplorationJoin + explorationID + explorationScopeSuffix
			explorePart := uiModelDisplayExplorationJoin + explorationID + styleChatMuted + explorationScopeSuffix
			blocks = append(blocks, styledInlineBlock(styledInlineBlockOptions{style: styleChatMagenta, text: explorePart}))
		}
		return content, blocks
	}
	if explorationID == "" {
		return "", nil
	}
	content := uiModelDisplayExplorationPrefix + explorationID + explorationScopeSuffix
	exploreText := styleChatMagenta + uiModelDisplayExplorationPrefix + explorationID + styleChatMuted + explorationScopeSuffix
	if offline {
		content += uiModelDisplayOffline
		exploreText += " \033[33m(offline)"
	}
	return content, []inlineBlock{newInlineBlock(exploreText)}
}

func (a *App) showOllamaOfflineNotice() {
	msg := fmt.Sprintf("\033[33m⚠\033[34;3m Ollama unreachable at \033[36m%s\033[34;3m — run '\033[32;3mollama serve\033[34;3m' to continue", a.config.ollamaBaseURL())
	providers := a.config.configuredProviders()
	delete(providers, ProviderOllama)
	if len(providers) > 0 {
		msg = fmt.Sprintf("\033[33m⚠\033[34;3m Ollama unreachable at \033[36m%s\033[34;3m — run '\033[32;3mollama serve\033[34;3m' or switch to another provider (/config)", a.config.ollamaBaseURL())
	}
	if msg == a.lastOllamaOfflineNotice {
		return
	}
	a.messages = append(a.messages, chatMessage{kind: msgInfo, content: msg})
	a.lastOllamaOfflineNotice = msg
}

func (a *App) normalizeProjectConfigWithCurrentModels() {
	if a.models == nil {
		return
	}
	normalized := normalizeProjectConfigForModels(normalizeProjectConfigForModelsOptions{pc: a.projectConfig, models: a.models})
	if normalized == a.projectConfig {
		return
	}
	a.projectConfig = normalized
	a.rebuildEffectiveConfig()
}

func (a *App) removeModelDiagnosticMessages() {
	kept := a.messages[:0]
	for _, msg := range a.messages {
		if !msg.modelDiagnostic {
			kept = append(kept, msg)
		}
	}
	a.messages = kept
}

func (a *App) showProjectModelDiagnostics() {
	diagnostics := a.projectModelDiagnostics()
	signature := strings.Join(diagnostics, "\n")
	if signature == a.lastModelDiagnostics {
		return
	}
	a.removeModelDiagnosticMessages()
	a.lastModelDiagnostics = signature
	for _, diagnostic := range diagnostics {
		a.messages = append(a.messages, chatMessage{
			kind:            msgInfo,
			content:         "\033[33m⚠\033[34;3m " + diagnostic,
			modelDiagnostic: true,
		})
	}
}

func (a *App) projectModelDiagnostics() []string {
	if !a.configReady || a.models == nil {
		return nil
	}
	if len(a.config.configuredDeploymentIDs()) == 0 && a.config.ActiveModel == "" && a.config.ExplorationModel == "" {
		return nil
	}
	var diagnostics []string
	if a.config.ActiveModel != "" {
		result := a.config.resolveActiveModelResult(a.models)
		if result.Fallback && result.Diagnostic != "" {
			diagnostics = append(diagnostics, result.Diagnostic)
		}
	}
	if a.config.ExplorationModel != "" {
		result := a.config.resolveExplorationModelResult(a.models)
		if result.Fallback && result.Diagnostic != "" {
			diagnostics = append(diagnostics, result.Diagnostic)
		}
	}
	return diagnostics
}

// maybeShowInitialModels shows the startup model line once both the model
// catalog and the project config have loaded, preventing a double display.
func (a *App) maybeShowInitialModels() {
	if a.shownInitialModel || !a.configReady || a.models == nil {
		return
	}
	a.normalizeProjectConfigWithCurrentModels()
	a.shownInitialModel = true
	a.messages = append(a.messages, versionDisplayMessage(a.backend))
	a.showProjectModelDiagnostics()
	a.showResolvedModelDisplay()
}

func versionDisplayMessage(backend backendKind) chatMessage {
	suffix := backendVersionSuffix(backend)
	content := "v" + Version + " " + suffix
	return chatMessage{
		kind:    msgInfo,
		content: content,
		inlineBlocks: []inlineBlock{
			styledInlineBlock(styledInlineBlockOptions{style: styleChatBlue, text: "v" + Version}),
			styledInlineBlock(styledInlineBlockOptions{style: styleChatBlue, text: suffix}),
		},
	}
}

func backendVersionSuffix(backend backendKind) string {
	if backend == backendCPSL {
		return "(sandbox: CPSL)"
	}
	if backend == backendNaked {
		return "(host: naked)"
	}
	return "(container: " + hermImageTag + ")"
}

func (a *App) refreshResolvedModelDisplay() {
	if !a.configReady {
		return
	}
	if a.models != nil {
		a.normalizeProjectConfigWithCurrentModels()
		a.showProjectModelDiagnostics()
	}
	a.showResolvedModelDisplay()
}

func (a *App) resolveMainAgentModelResult() configuredModelResolution {
	if explicitActiveModelConfigured(a.effectiveModelConfig()) {
		return a.config.resolveActiveModelResult(a.models)
	}
	return a.config.resolveExplorationModelResult(a.models)
}

func (a *App) projectModelConfig() projectModelConfigOptions {
	return projectModelConfigOptions{global: a.globalConfig, project: a.projectConfig}
}

func (a *App) effectiveModelConfig() projectModelConfigOptions {
	if strings.TrimSpace(a.cliConfigOverrides) == "" {
		return a.projectModelConfig()
	}
	return projectModelConfigOptions{global: a.config, project: ProjectConfig{}}
}
