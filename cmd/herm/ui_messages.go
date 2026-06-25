// ui_messages.go centralizes user-facing chat and config editor copy.
package main

import (
	"fmt"
	"strings"
)

// Config field labels shown in the config editor and save notices.
const (
	uiConfigLabelActiveModel             = "Model"
	uiConfigLabelExplorationModel        = "Exploration"
	uiConfigLabelProjectActiveModel      = "Project Model"
	uiConfigLabelProjectExplorationModel = "Project Exploration"
)

const uiConfigLabelAPIKeySubstring = "API Key"

// Config change directions stored in cfgChangedLabels.
const (
	uiConfigChangeSaved   = "saved"
	uiConfigChangeUpdated = "updated"
	uiConfigChangeRemoved = "removed"
)

// Config save notice suffixes.
const (
	uiConfigNoticeSaved   = " saved."
	uiConfigNoticeUpdated = " updated."
	uiConfigNoticeUnset   = " unset."
	uiConfigNoticeRemoved = " removed."
	uiConfigEmptySave     = "Config saved."
)

// Model resolution scope tags for the status line.
const (
	uiModelScopeGlobal  = "global"
	uiModelScopeProject = "project"
)

// Model status line copy.
const (
	uiModelDisplayActivePrefix      = "Model: "
	uiModelDisplayExplorationPrefix = "Exploration: "
	uiModelDisplayExplorationJoin   = "Exploration: "
	uiModelDisplayOffline           = " (offline)"
)

// Gating and error messages.
const (
	configMissingAPIKeyMessage   = "No API keys configured. Use /config to add a key first."
	configMissingModelMessage    = "No model configured. Use /model to select one first."
	configSelectModelHintMessage = "Select Model (/model)."
)

type configFieldNoticeContentOptions struct {
	label  string
	suffix string
}

func configFieldNoticeContent(opts configFieldNoticeContentOptions) string {
	return opts.label + opts.suffix
}

func modelScopeSuffix(scope string) string {
	if scope == "" {
		return ""
	}
	return fmt.Sprintf(" (%s)", scope)
}

func isAPIKeyConfigLabel(label string) bool {
	return strings.Contains(label, uiConfigLabelAPIKeySubstring)
}

func isActiveModelConfigLabel(label string) bool {
	switch label {
	case uiConfigLabelActiveModel, uiConfigLabelProjectActiveModel:
		return true
	default:
		return false
	}
}

func isExplorationModelConfigLabel(label string) bool {
	switch label {
	case uiConfigLabelExplorationModel, uiConfigLabelProjectExplorationModel:
		return true
	default:
		return false
	}
}

type configChangeLabelForFieldOptions struct {
	field      cfgField
	projectTab bool
}

func configChangeLabelForField(opts configChangeLabelForFieldOptions) string {
	if !opts.projectTab {
		return opts.field.label
	}
	switch opts.field.label {
	case uiConfigLabelActiveModel:
		return uiConfigLabelProjectActiveModel
	case uiConfigLabelExplorationModel:
		return uiConfigLabelProjectExplorationModel
	default:
		return opts.field.label
	}
}
