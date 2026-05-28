// ui_messages.go centralizes user-facing chat and config editor copy.
package main

import (
	"fmt"
	"strings"
)

// Config field labels shown in the config editor and save notices.
const (
	uiConfigLabelActiveModel             = "Active Model"
	uiConfigLabelExplorationModel        = "Exploration Model"
	uiConfigLabelProjectActiveModel      = "Project Active Model"
	uiConfigLabelProjectExplorationModel = "Project Exploration Model"
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
	uiConfigNoticeCleared = " cleared."
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
	uiModelDisplayActivePrefix      = "Using active: "
	uiModelDisplayExplorationPrefix = "Using exploration: "
	uiModelDisplayExplorationJoin   = ", exploration: "
	uiModelDisplayOffline           = " (offline)"
)

// Gating and error messages.
const (
	configMissingAPIKeyMessage = "No API keys configured. Use /config to add a key first."
	configMissingModelMessage  = "No model configured. Use /model to select one first."
)

func configFieldNoticeContent(label, suffix string) string {
	return label + suffix
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
