// configeditor_deployments.go defines deployment credential fields and
// helper routines used by the interactive config editor.
package main

import (
	"sort"
	"strings"
)

func maskKey(key string) string {
	if key == "" {
		return "(not set)"
	}
	if len(key) <= 8 {
		return "****"
	}
	return key[:4] + "..." + key[len(key)-4:]
}

var cfgAPIKeyFields = []cfgField{
	deploymentTextField(deploymentTextFieldOptions{label: "Anthropic Direct API Key", deploymentID: "anthropic-direct", field: "api_key", secret: true}),
	deploymentTextField(deploymentTextFieldOptions{label: "OpenAI Direct API Key", deploymentID: "openai-direct", field: "api_key", secret: true}),
	deploymentTextField(deploymentTextFieldOptions{label: "Grok Direct API Key", deploymentID: "grok-direct", field: "api_key", secret: true}),
	deploymentTextField(deploymentTextFieldOptions{label: "OpenRouter API Key", deploymentID: "openrouter", field: "api_key", secret: true}),
	deploymentTextField(deploymentTextFieldOptions{label: "Gemini Direct API Key", deploymentID: "gemini-direct", field: "api_key", secret: true}),
	deploymentTextField(deploymentTextFieldOptions{label: "Ollama Base URL", deploymentID: "ollama-local", field: "base_url", normalizeURL: true}),
	deploymentTextField(deploymentTextFieldOptions{label: "OpenAI Direct Base URL", deploymentID: "openai-direct", field: "base_url", normalizeURL: true}),
	deploymentTextField(deploymentTextFieldOptions{label: "Azure OpenAI API Key", deploymentID: "openai-azure", field: "api_key", secret: true}),
	deploymentTextField(deploymentTextFieldOptions{label: "Azure OpenAI Endpoint", deploymentID: "openai-azure", field: "endpoint", normalizeURL: true}),
	deploymentTextField(deploymentTextFieldOptions{label: "Azure OpenAI API Version", deploymentID: "openai-azure", field: "api_version"}),
	deploymentModelMappingsField(deploymentModelMappingsFieldOptions{label: "Azure Model Mappings", deploymentID: "openai-azure"}),
	deploymentTextField(deploymentTextFieldOptions{label: "Anthropic Bedrock Region", deploymentID: "anthropic-bedrock", field: "region"}),
	deploymentTextField(deploymentTextFieldOptions{label: "Anthropic Vertex Project", deploymentID: "anthropic-vertex", field: "project_id"}),
	deploymentTextField(deploymentTextFieldOptions{label: "Anthropic Vertex Region", deploymentID: "anthropic-vertex", field: "region"}),
	deploymentTextField(deploymentTextFieldOptions{label: "Gemini Vertex Project", deploymentID: "gemini-vertex", field: "project_id"}),
	deploymentTextField(deploymentTextFieldOptions{label: "Gemini Vertex Region", deploymentID: "gemini-vertex", field: "region"}),
	deploymentTextField(deploymentTextFieldOptions{label: "Grok Base URL", deploymentID: "grok-direct", field: "base_url", normalizeURL: true}),
	deploymentTextField(deploymentTextFieldOptions{label: "OpenRouter Base URL", deploymentID: "openrouter", field: "base_url", normalizeURL: true}),
}

// deploymentTextFieldOptions is the parameter bundle for deploymentTextField.
type deploymentTextFieldOptions struct {
	label        string
	deploymentID string
	field        string
	secret       bool
	normalizeURL bool
}

func deploymentTextField(opts deploymentTextFieldOptions) cfgField {
	label, deploymentID, field := opts.label, opts.deploymentID, opts.field
	secret, normalizeURL := opts.secret, opts.normalizeURL
	get := func(c Config) string {
		return deploymentFieldValue(deploymentFieldValueOptions{deployment: c.deploymentConfigs()[deploymentID], field: field})
	}
	display := func(c Config) string {
		value := get(c)
		if secret {
			return maskKey(value)
		}
		return value
	}
	return cfgField{
		label: label,
		get:   get,
		display: func(c Config) string {
			if secret {
				return display(c)
			}
			return get(c)
		},
		set: func(c *Config, v string) {
			v = strings.TrimSpace(v)
			if normalizeURL && v != "" && !strings.HasPrefix(v, "http://") && !strings.HasPrefix(v, "https://") {
				v = "http://" + v
			}
			setConfigDeploymentField(setConfigDeploymentFieldOptions{cfg: c, deploymentID: deploymentID, field: field, value: v})
		},
	}
}

// deploymentModelMappingsFieldOptions is the parameter bundle for deploymentModelMappingsField.
type deploymentModelMappingsFieldOptions struct {
	label        string
	deploymentID string
}

func deploymentModelMappingsField(opts deploymentModelMappingsFieldOptions) cfgField {
	label, deploymentID := opts.label, opts.deploymentID
	return cfgField{
		label:   label,
		get:     func(c Config) string { return formatStringMap(c.deploymentConfigs()[deploymentID].ModelMappings) },
		display: func(c Config) string { return formatStringMap(c.deploymentConfigs()[deploymentID].ModelMappings) },
		set: func(c *Config, v string) {
			mappings := parseStringMap(v)
			ensureDeploymentConfig(ensureDeploymentConfigOptions{cfg: c, deploymentID: deploymentID})
			deployment := c.Deployments[deploymentID]
			deployment.ModelMappings = mappings
			setConfigDeployment(setConfigDeploymentOptions{cfg: c, deploymentID: deploymentID, deployment: deployment})
		},
	}
}

// ensureDeploymentConfigOptions is the parameter bundle for ensureDeploymentConfig.
type ensureDeploymentConfigOptions struct {
	cfg          *Config
	deploymentID string
}

func ensureDeploymentConfig(opts ensureDeploymentConfigOptions) {
	c, deploymentID := opts.cfg, opts.deploymentID
	if c.Deployments == nil {
		c.Deployments = map[string]DeploymentConfig{}
	}
	if _, ok := c.Deployments[deploymentID]; !ok {
		c.Deployments[deploymentID] = DeploymentConfig{}
	}
}

// setConfigDeploymentOptions is the parameter bundle for setConfigDeployment.
type setConfigDeploymentOptions struct {
	cfg          *Config
	deploymentID string
	deployment   DeploymentConfig
}

func setConfigDeployment(opts setConfigDeploymentOptions) {
	c, deploymentID, deployment := opts.cfg, opts.deploymentID, opts.deployment
	if deploymentConfigIsEmpty(deployment) {
		delete(c.Deployments, deploymentID)
		if len(c.Deployments) == 0 {
			c.Deployments = nil
		}
		return
	}
	ensureDeploymentConfig(ensureDeploymentConfigOptions{cfg: c, deploymentID: deploymentID})
	c.Deployments[deploymentID] = deployment
}

// setConfigDeploymentFieldOptions is the parameter bundle for setConfigDeploymentField.
type setConfigDeploymentFieldOptions struct {
	cfg          *Config
	deploymentID string
	field        string
	value        string
}

func setConfigDeploymentField(opts setConfigDeploymentFieldOptions) {
	c, deploymentID, field, value := opts.cfg, opts.deploymentID, opts.field, opts.value
	ensureDeploymentConfig(ensureDeploymentConfigOptions{cfg: c, deploymentID: deploymentID})
	deployment := c.Deployments[deploymentID]
	setDeploymentFieldValue(setDeploymentFieldValueOptions{deployment: &deployment, field: field, value: value})
	setConfigDeployment(setConfigDeploymentOptions{cfg: c, deploymentID: deploymentID, deployment: deployment})
	setLegacyDeploymentField(setLegacyDeploymentFieldOptions{cfg: c, deploymentID: deploymentID, field: field, value: value})
}

// setLegacyDeploymentFieldOptions is the parameter bundle for setLegacyDeploymentField.
type setLegacyDeploymentFieldOptions struct {
	cfg          *Config
	deploymentID string
	field        string
	value        string
}

func setLegacyDeploymentField(opts setLegacyDeploymentFieldOptions) {
	c, deploymentID, field, value := opts.cfg, opts.deploymentID, opts.field, opts.value
	switch {
	case deploymentID == "anthropic-direct" && field == "api_key":
		c.AnthropicAPIKey = value
	case deploymentID == "openai-direct" && field == "api_key":
		c.OpenAIAPIKey = value
	case deploymentID == "grok-direct" && field == "api_key":
		c.GrokAPIKey = value
	case deploymentID == "openrouter" && field == "api_key":
		c.OpenRouterAPIKey = value
	case deploymentID == "gemini-direct" && field == "api_key":
		c.GeminiAPIKey = value
	case deploymentID == "ollama-local" && field == "base_url":
		c.OllamaBaseURL = value
	}
}

func formatStringMap(values map[string]string) string {
	if len(values) == 0 {
		return ""
	}
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	parts := make([]string, 0, len(keys))
	for _, key := range keys {
		parts = append(parts, key+"="+values[key])
	}
	return strings.Join(parts, ",")
}

func parseStringMap(value string) map[string]string {
	value = strings.TrimSpace(value)
	if value == "" {
		return nil
	}
	value = strings.ReplaceAll(value, ";", ",")
	parts := strings.Split(value, ",")
	out := map[string]string{}
	for _, part := range parts {
		key, val, ok := strings.Cut(strings.TrimSpace(part), "=")
		if !ok {
			key, val, ok = strings.Cut(strings.TrimSpace(part), ":")
		}
		key = strings.TrimSpace(key)
		val = strings.TrimSpace(val)
		if ok && key != "" && val != "" {
			out[key] = val
		}
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

func apiKeyRowForProvider(provider string) int {
	switch provider {
	case ProviderAnthropic:
		return 0
	case ProviderOpenAI:
		return 1
	case ProviderGrok:
		return 2
	case ProviderOpenRouter:
		return 3
	case ProviderGemini:
		return 4
	case ProviderOllama:
		return 5
	default:
		return 0
	}
}
