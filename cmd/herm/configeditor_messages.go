// configeditor_messages.go builds config save chat notices and model-selection hints.
package main

import (
	"sort"
)

type recordConfigChangeOptions struct {
	changed       map[string]string
	label, oldVal string
	newVal        string
}

func recordConfigChange(opts recordConfigChangeOptions) {
	if opts.oldVal == opts.newVal {
		return
	}
	if opts.oldVal == "" {
		opts.changed[opts.label] = uiConfigChangeSaved
	} else if opts.newVal == "" {
		opts.changed[opts.label] = uiConfigChangeRemoved
	} else {
		opts.changed[opts.label] = uiConfigChangeUpdated
	}
}

type configChangeNotice struct {
	content string
	style   string
}

type configChangeNoticeForOptions struct {
	label     string
	direction string
}

func configChangeNoticeFor(opts configChangeNoticeForOptions) configChangeNotice {
	if isModelConfigLabel(opts.label) {
		return modelConfigChangeNotice(opts)
	}
	profile := configNoticeProfileFor(opts.label)
	switch opts.direction {
	case uiConfigChangeSaved:
		return configChangeNotice{
			content: configFieldNoticeContent(configFieldNoticeContentOptions{label: opts.label, suffix: uiConfigNoticeSaved}),
			style:   profile.accentStyle,
		}
	case uiConfigChangeRemoved:
		return configChangeNotice{
			content: configFieldNoticeContent(configFieldNoticeContentOptions{label: opts.label, suffix: profile.removedSuffix}),
			style:   styleChatRed,
		}
	default:
		return configChangeNotice{
			content: configFieldNoticeContent(configFieldNoticeContentOptions{label: opts.label, suffix: uiConfigNoticeUpdated}),
			style:   styleChatDimYellow,
		}
	}
}

func isModelConfigLabel(label string) bool {
	return isActiveModelConfigLabel(label) || isExplorationModelConfigLabel(label)
}

func modelConfigChangeNotice(opts configChangeNoticeForOptions) configChangeNotice {
	switch opts.direction {
	case uiConfigChangeSaved:
		return configChangeNotice{
			content: configFieldNoticeContent(configFieldNoticeContentOptions{label: opts.label, suffix: uiConfigNoticeSaved}),
			style:   styleChatDimGreen,
		}
	case uiConfigChangeRemoved:
		return configChangeNotice{
			content: configFieldNoticeContent(configFieldNoticeContentOptions{label: opts.label, suffix: uiConfigNoticeUnset}),
			style:   styleChatDimRed,
		}
	default:
		return configChangeNotice{
			content: configFieldNoticeContent(configFieldNoticeContentOptions{label: opts.label, suffix: uiConfigNoticeUpdated}),
			style:   styleChatDimYellow,
		}
	}
}

type configNoticeProfile struct {
	accentStyle   string
	removedSuffix string
}

func configNoticeProfileFor(label string) configNoticeProfile {
	switch {
	case isActiveModelConfigLabel(label):
		return configNoticeProfile{accentStyle: styleChatCyan, removedSuffix: uiConfigNoticeUnset}
	case isExplorationModelConfigLabel(label):
		return configNoticeProfile{accentStyle: styleChatMagenta, removedSuffix: uiConfigNoticeUnset}
	case isAPIKeyConfigLabel(label):
		return configNoticeProfile{accentStyle: styleChatGreen, removedSuffix: uiConfigNoticeRemoved}
	default:
		return configNoticeProfile{accentStyle: styleChatBlue, removedSuffix: uiConfigNoticeRemoved}
	}
}

func configSavedMessages(changed map[string]string) []chatMessage {
	if len(changed) == 0 {
		return []chatMessage{configChangeChatMessage(configChangeNotice{
			content: uiConfigEmptySave,
			style:   styleChatMuted,
		})}
	}
	labels := make([]string, 0, len(changed))
	for label := range changed {
		labels = append(labels, label)
	}
	sort.Strings(labels)

	msgs := make([]chatMessage, 0, len(labels))
	for _, label := range labels {
		msgs = append(msgs, configChangeChatMessage(configChangeNoticeFor(configChangeNoticeForOptions{
			label:     label,
			direction: changed[label],
		})))
	}
	return msgs
}

func configMissingModelChatMessage() chatMessage {
	return chatMessage{kind: msgError, content: configMissingModelMessage}
}

func configSelectModelHintChatMessage() chatMessage {
	return configChangeChatMessage(configChangeNotice{
		content: configSelectModelHintMessage,
		style:   styleChatBlue,
	})
}

func appendMissingModelMessageIfNeeded(messages []chatMessage) []chatMessage {
	return append(messages, configMissingModelChatMessage())
}

type projectModelConfigOptions struct {
	global  Config
	project ProjectConfig
}

func explicitActiveModelConfigured(opts projectModelConfigOptions) bool {
	return opts.global.ActiveModel != "" || opts.project.ActiveModel != ""
}

func explicitExplorationModelConfigured(opts projectModelConfigOptions) bool {
	return opts.global.ExplorationModel != "" || opts.project.ExplorationModel != ""
}

func explicitConfiguredActiveModelID(opts projectModelConfigOptions) string {
	if opts.project.ActiveModel != "" {
		return opts.project.ActiveModel
	}
	return opts.global.ActiveModel
}

func explicitConfiguredExplorationModelID(opts projectModelConfigOptions) string {
	if opts.project.ExplorationModel != "" {
		return opts.project.ExplorationModel
	}
	return opts.global.ExplorationModel
}

func activeModelConfigScope(opts projectModelConfigOptions) string {
	if opts.project.ActiveModel != "" {
		return uiModelScopeProject
	}
	if opts.global.ActiveModel != "" {
		return uiModelScopeGlobal
	}
	return ""
}

func explorationModelConfigScope(opts projectModelConfigOptions) string {
	if opts.project.ExplorationModel != "" {
		return uiModelScopeProject
	}
	if opts.global.ExplorationModel != "" {
		return uiModelScopeGlobal
	}
	return ""
}

func modelsReadyForAgent(opts projectModelConfigOptions) bool {
	return explicitActiveModelConfigured(opts) || explicitExplorationModelConfigured(opts)
}

func configNeedsModelSelection(opts projectModelConfigOptions) bool {
	if modelsReadyForAgent(opts) {
		return false
	}
	return len(opts.global.configuredProviders()) > 0
}

func chatHasSelectModelHintMessage(messages []chatMessage) bool {
	for _, msg := range messages {
		if msg.content == configSelectModelHintMessage {
			return true
		}
	}
	return false
}

type configSavedMessagesWithHintsOptions struct {
	changed  map[string]string
	cfg      Config
	project  ProjectConfig
	existing []chatMessage
}

func configSavedMessagesWithHints(opts configSavedMessagesWithHintsOptions) []chatMessage {
	msgs := configSavedMessages(opts.changed)
	if !configNeedsModelSelection(projectModelConfigOptions{global: opts.cfg, project: opts.project}) {
		return msgs
	}
	apiKeyChanged := false
	for label, direction := range opts.changed {
		if direction != uiConfigChangeRemoved && isAPIKeyConfigLabel(label) {
			apiKeyChanged = true
			break
		}
	}
	if !apiKeyChanged {
		return msgs
	}
	out := make([]chatMessage, 0, len(msgs)+1)
	out = append(out, msgs...)
	if !chatHasSelectModelHintMessage(opts.existing) && !chatHasSelectModelHintMessage(out) {
		out = append(out, configSelectModelHintChatMessage())
	}
	return out
}

func configChangeChatMessage(notice configChangeNotice) chatMessage {
	return chatMessage{
		kind:    msgInfo,
		content: notice.content,
		inlineBlocks: []inlineBlock{
			styledInlineBlock(styledInlineBlockOptions{style: notice.style, text: notice.content}),
		},
	}
}
