// configeditor_messages.go builds config save chat notices and model-selection hints.
package main

import (
	"sort"
	"strings"
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
		opts.changed[opts.label] = "saved"
	} else if opts.newVal == "" {
		opts.changed[opts.label] = "removed"
	} else {
		opts.changed[opts.label] = "updated"
	}
}

type configChangeNotice struct {
	content string
	style   string
}

func isActiveModelConfigLabel(label string) bool {
	switch label {
	case "Active Model", "Project Active Model":
		return true
	default:
		return false
	}
}

func isExplorationModelConfigLabel(label string) bool {
	switch label {
	case "Exploration Model", "Project Exploration Model":
		return true
	default:
		return false
	}
}

func isAPIKeyConfigLabel(label string) bool {
	return strings.Contains(label, "API Key")
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
	case "saved":
		return configChangeNotice{content: opts.label + " saved.", style: styleChatCyan}
	case "removed":
		return configChangeNotice{content: opts.label + " cleared.", style: styleChatRed}
	default:
		return configChangeNotice{content: opts.label + " updated.", style: styleChatYellow}
	}
}

func explorationModelConfigNotice(opts configChangeNoticeForOptions) configChangeNotice {
	switch opts.direction {
	case "saved":
		return configChangeNotice{content: opts.label + " saved.", style: styleChatMagenta}
	case "removed":
		return configChangeNotice{content: opts.label + " cleared.", style: styleChatRed}
	default:
		return configChangeNotice{content: opts.label + " updated.", style: styleChatYellow}
	}
}

func apiKeyConfigNotice(opts configChangeNoticeForOptions) configChangeNotice {
	switch opts.direction {
	case "saved":
		return configChangeNotice{content: opts.label + " saved.", style: styleChatGreen}
	case "removed":
		return configChangeNotice{content: opts.label + " removed.", style: styleChatRed}
	default:
		return configChangeNotice{content: opts.label + " updated.", style: styleChatYellow}
	}
}

func genericConfigNotice(opts configChangeNoticeForOptions) configChangeNotice {
	switch opts.direction {
	case "saved":
		return configChangeNotice{content: opts.label + " saved.", style: styleChatBlue}
	case "removed":
		return configChangeNotice{content: opts.label + " removed.", style: styleChatRed}
	default:
		return configChangeNotice{content: opts.label + " updated.", style: styleChatYellow}
	}
}

func configSavedMessages(changed map[string]string) []chatMessage {
	if len(changed) == 0 {
		return []chatMessage{configChangeChatMessage(configChangeNotice{
			content: "Config saved.",
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

const configMissingAPIKeyMessage = "No API keys configured. Use /config to add a key first."
const configMissingModelMessage = "No model configured. Use /model to select one first."

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
		return "project"
	}
	if opts.global.ActiveModel != "" {
		return "global"
	}
	return ""
}

func explorationModelConfigScope(opts projectModelConfigOptions) string {
	if opts.project.ExplorationModel != "" {
		return "project"
	}
	if opts.global.ExplorationModel != "" {
		return "global"
	}
	return ""
}

func modelScopeSuffix(scope string) string {
	if scope == "" {
		return ""
	}
	return " (" + scope + ")"
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
		if direction != "removed" && isAPIKeyConfigLabel(label) {
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
