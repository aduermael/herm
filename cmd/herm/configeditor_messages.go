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
	switch {
	case isActiveModelConfigLabel(opts.label):
		return activeModelConfigNotice(opts)
	case isExplorationModelConfigLabel(opts.label):
		return explorationModelConfigNotice(opts)
	case isAPIKeyConfigLabel(opts.label):
		return apiKeyConfigNotice(opts)
	default:
		return genericConfigNotice(opts)
	}
}

func activeModelConfigNotice(opts configChangeNoticeForOptions) configChangeNotice {
	switch opts.direction {
	case uiConfigChangeSaved:
		return configChangeNotice{content: configFieldNoticeContent(opts.label, uiConfigNoticeSaved), style: styleChatCyan}
	case uiConfigChangeRemoved:
		return configChangeNotice{content: configFieldNoticeContent(opts.label, uiConfigNoticeCleared), style: styleChatRed}
	default:
		return configChangeNotice{content: configFieldNoticeContent(opts.label, uiConfigNoticeUpdated), style: styleChatYellow}
	}
}

func explorationModelConfigNotice(opts configChangeNoticeForOptions) configChangeNotice {
	switch opts.direction {
	case uiConfigChangeSaved:
		return configChangeNotice{content: configFieldNoticeContent(opts.label, uiConfigNoticeSaved), style: styleChatMagenta}
	case uiConfigChangeRemoved:
		return configChangeNotice{content: configFieldNoticeContent(opts.label, uiConfigNoticeCleared), style: styleChatRed}
	default:
		return configChangeNotice{content: configFieldNoticeContent(opts.label, uiConfigNoticeUpdated), style: styleChatYellow}
	}
}

func apiKeyConfigNotice(opts configChangeNoticeForOptions) configChangeNotice {
	switch opts.direction {
	case uiConfigChangeSaved:
		return configChangeNotice{content: configFieldNoticeContent(opts.label, uiConfigNoticeSaved), style: styleChatGreen}
	case uiConfigChangeRemoved:
		return configChangeNotice{content: configFieldNoticeContent(opts.label, uiConfigNoticeRemoved), style: styleChatRed}
	default:
		return configChangeNotice{content: configFieldNoticeContent(opts.label, uiConfigNoticeUpdated), style: styleChatYellow}
	}
}

func genericConfigNotice(opts configChangeNoticeForOptions) configChangeNotice {
	switch opts.direction {
	case uiConfigChangeSaved:
		return configChangeNotice{content: configFieldNoticeContent(opts.label, uiConfigNoticeSaved), style: styleChatBlue}
	case uiConfigChangeRemoved:
		return configChangeNotice{content: configFieldNoticeContent(opts.label, uiConfigNoticeRemoved), style: styleChatRed}
	default:
		return configChangeNotice{content: configFieldNoticeContent(opts.label, uiConfigNoticeUpdated), style: styleChatYellow}
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

func chatHasMissingModelMessage(messages []chatMessage) bool {
	for _, msg := range messages {
		if msg.content == configMissingModelMessage {
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
	if !chatHasMissingModelMessage(opts.existing) && !chatHasMissingModelMessage(out) {
		out = append(out, configMissingModelChatMessage())
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
