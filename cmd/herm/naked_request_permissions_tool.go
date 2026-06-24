// naked_request_permissions_tool.go implements naked-mode permission request tooling.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"

	"langdag.com/langdag/types"
)

func normalizeBashSandboxPermissions(value string) (string, error) {
	switch strings.TrimSpace(value) {
	case "", bashSandboxPermissionsUseDefault:
		return bashSandboxPermissionsUseDefault, nil
	case bashSandboxPermissionsWithAdditional:
		return bashSandboxPermissionsWithAdditional, nil
	case bashSandboxPermissionsRequireEscalated:
		return bashSandboxPermissionsRequireEscalated, nil
	default:
		return "", fmt.Errorf("unsupported sandbox_permissions %q", value)
	}
}

type validateBashAdditionalPermissionsOptions struct {
	sandboxPermissions string
	permissions        bashAdditionalPermissions
}

func validateBashAdditionalPermissions(opts validateBashAdditionalPermissionsOptions) (bashAdditionalPermissions, error) {
	opts.permissions.FileSystem.Read = uniqueSortedStrings(opts.permissions.FileSystem.Read)
	opts.permissions.FileSystem.Write = uniqueSortedStrings(opts.permissions.FileSystem.Write)
	hasPermissions := !opts.permissions.empty()
	if opts.sandboxPermissions == bashSandboxPermissionsWithAdditional {
		if !hasPermissions {
			return bashAdditionalPermissions{}, fmt.Errorf("missing additional_permissions; provide network or file_system permissions with sandbox_permissions with_additional_permissions")
		}
		return opts.permissions, nil
	}
	if hasPermissions {
		return bashAdditionalPermissions{}, fmt.Errorf("additional_permissions requires sandbox_permissions with_additional_permissions")
	}
	return bashAdditionalPermissions{}, nil
}

func (p bashAdditionalPermissions) empty() bool {
	return !p.Network.Enabled && len(p.FileSystem.Read) == 0 && len(p.FileSystem.Write) == 0
}

func (p bashAdditionalPermissions) fileSystemPaths() (readPaths, writePaths []string) {
	return p.FileSystem.Read, p.FileSystem.Write
}

type bashApprovalCommandOptions struct {
	command               string
	sandboxPermissions    string
	additionalPermissions bashAdditionalPermissions
}

func bashApprovalCommand(opts bashApprovalCommandOptions) string {
	prefix := ""
	switch opts.sandboxPermissions {
	case bashSandboxPermissionsRequireEscalated:
		prefix = nakedEscalatedApprovalPrefix
	case bashSandboxPermissionsWithAdditional:
		prefix = nakedAdditionalApprovalPrefix
	}
	if prefix == "" {
		return opts.command
	}
	tokens := bashAdditionalPermissionApprovalTokens(opts.additionalPermissions)
	var scoped []string
	for _, segment := range commandApprovalSegments(opts.command) {
		segment = strings.TrimSpace(segment)
		if segment == "" {
			continue
		}
		if len(tokens) > 0 {
			segment = strings.Join(tokens, " ") + " " + segment
		}
		scoped = append(scoped, prefix+segment)
	}
	if len(scoped) == 0 {
		return prefix + opts.command
	}
	return strings.Join(scoped, " && ")
}

func bashAdditionalPermissionApprovalTokens(permissions bashAdditionalPermissions) []string {
	var tokens []string
	if permissions.Network.Enabled {
		tokens = append(tokens, "network.enabled=true")
	}
	for _, path := range permissions.FileSystem.Read {
		tokens = append(tokens, "__herm_read="+strconv.Quote(path))
	}
	for _, path := range permissions.FileSystem.Write {
		tokens = append(tokens, "__herm_write="+strconv.Quote(path))
	}
	return tokens
}

type bashApprovalPrefixRulesOptions struct {
	prefixRule            []string
	sandboxPermissions    string
	additionalPermissions bashAdditionalPermissions
}

func bashApprovalPrefixRules(opts bashApprovalPrefixRulesOptions) [][]string {
	normalized := normalizeCommandPrefixRule(opts.prefixRule)
	if len(normalized) == 0 {
		return nil
	}
	switch opts.sandboxPermissions {
	case bashSandboxPermissionsRequireEscalated:
		return [][]string{append([]string{strings.TrimSpace(nakedEscalatedApprovalPrefix)}, normalized...)}
	case bashSandboxPermissionsWithAdditional:
		tokens := bashAdditionalPermissionApprovalTokens(opts.additionalPermissions)
		rule := []string{strings.TrimSpace(nakedAdditionalApprovalPrefix)}
		rule = append(rule, tokens...)
		rule = append(rule, normalized...)
		return [][]string{rule}
	default:
		return [][]string{normalized}
	}
}

type RequestPermissionsTool struct {
	permissions *nakedPermissionStore
}

func NewNakedRequestPermissionsTool(workDir string) *RequestPermissionsTool {
	return NewNakedRequestPermissionsToolWithStore(newNakedRequestPermissionsToolWithStoreOptions{workDir: workDir})
}

type newNakedRequestPermissionsToolWithStoreOptions struct {
	workDir string
	store   *nakedPermissionStore
}

func NewNakedRequestPermissionsToolWithStore(opts newNakedRequestPermissionsToolWithStoreOptions) *RequestPermissionsTool {
	store := opts.store
	if store == nil {
		store = newNakedPermissionStore(newNakedPermissionStoreOptions{
			path:      nakedPermissionsPath(opts.workDir),
			workspace: opts.workDir,
		})
	}
	return &RequestPermissionsTool{
		permissions: store,
	}
}

func (t *RequestPermissionsTool) Definition() types.ToolDefinition {
	return types.ToolDefinition{
		Name:        toolRequestPermissions,
		Description: getToolDescription(getToolDescriptionOptions{name: toolRequestPermissions, fallback: "Request sandboxed file or network permissions before running a host command."}),
		InputSchema: json.RawMessage(`{
			"type": "object",
			"properties": {
				"permissions": {
					"type": "object",
					"description": "Sandboxed filesystem or network permissions to request.",
					"properties": {
						"network": {
							"type": "object",
							"properties": {
								"enabled": {"type": "boolean"}
							}
						},
						"file_system": {
							"type": "object",
							"properties": {
								"read": {
									"type": "array",
									"items": {"type": "string"}
								},
								"write": {
									"type": "array",
									"items": {"type": "string"}
								}
							}
						}
					}
				}
			},
			"required": ["permissions"]
		}`),
	}
}

func (t *RequestPermissionsTool) Execute(_ context.Context, input json.RawMessage) (string, error) {
	permissions, err := parseRequestPermissionsInput(input)
	if err != nil {
		return "", err
	}
	if permissions.empty() {
		return "", fmt.Errorf("request_permissions requires at least one permission")
	}
	return `{"approved":true}`, nil
}

func (t *RequestPermissionsTool) RequiresApproval(input json.RawMessage) bool {
	permissions, err := parseRequestPermissionsInput(input)
	if err != nil || permissions.empty() || t.permissions == nil {
		return false
	}
	return t.permissions.RequestedPermissionsRequireApproval(permissions)
}

func (t *RequestPermissionsTool) HostTool() bool { return true }

func (t *RequestPermissionsTool) RecordApproval(opts recordToolApprovalOptions) error {
	permissions, err := parseRequestPermissionsInput(opts.input)
	if err != nil {
		return err
	}
	if permissions.empty() || t.permissions == nil {
		return nil
	}
	return t.permissions.RecordRequestedPermissions(recordRequestedPermissionsOptions{
		permissions: permissions,
		remember:    opts.remember,
	})
}

func parseRequestPermissionsInput(input json.RawMessage) (bashAdditionalPermissions, error) {
	var in requestPermissionsInput
	if err := json.Unmarshal(sanitizeToolJSON(input), &in); err != nil {
		return bashAdditionalPermissions{}, fmt.Errorf("invalid request_permissions input: %w", err)
	}
	return validateRequestedPermissions(in.Permissions)
}

func validateRequestedPermissions(permissions bashAdditionalPermissions) (bashAdditionalPermissions, error) {
	permissions.FileSystem.Read = uniqueSortedStrings(permissions.FileSystem.Read)
	permissions.FileSystem.Write = uniqueSortedStrings(permissions.FileSystem.Write)
	return permissions, nil
}
