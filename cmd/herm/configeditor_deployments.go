// configeditor_deployments.go defines deployment credential fields and
// helper routines used by the interactive config editor.
package main

import (
	"os"
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

var cfgAPIKeyFields = deploymentFieldsFromSpecs(deploymentFieldsFromSpecsOptions{
	cfg:               Config{},
	includeContextual: true,
})

type deploymentFieldVisibility int

const (
	deploymentFieldAlways deploymentFieldVisibility = iota
	deploymentFieldAzureContext
	deploymentFieldBedrockContext
	deploymentFieldVertexContext
)

type deploymentFieldSpec struct {
	field      cfgField
	visibility deploymentFieldVisibility
}

var cfgAPIKeyFieldSpecs = []deploymentFieldSpec{
	{field: deploymentTextField(deploymentTextFieldOptions{label: "Anthropic API Key", deploymentID: "anthropic-direct", field: "api_key", secret: true})},
	{field: deploymentTextField(deploymentTextFieldOptions{label: "OpenAI API Key", deploymentID: "openai-direct", field: "api_key", secret: true})},
	{field: deploymentTextField(deploymentTextFieldOptions{label: "Grok API Key", deploymentID: "grok-direct", field: "api_key", secret: true})},
	{field: deploymentTextField(deploymentTextFieldOptions{label: "OpenRouter API Key", deploymentID: "openrouter", field: "api_key", secret: true})},
	{field: deploymentTextField(deploymentTextFieldOptions{label: "Gemini API Key", deploymentID: "gemini-direct", field: "api_key", secret: true})},
	{field: deploymentTextField(deploymentTextFieldOptions{label: "Ollama Base URL", deploymentID: "ollama-local", field: "base_url", normalizeURL: true})},
	{field: deploymentTextField(deploymentTextFieldOptions{label: "Azure OpenAI API Key", deploymentID: "openai-azure", field: "api_key", secret: true})},
	{field: deploymentTextField(deploymentTextFieldOptions{label: "Azure OpenAI Endpoint", deploymentID: "openai-azure", field: "endpoint", normalizeURL: true, indent: 1, optional: true}), visibility: deploymentFieldAzureContext},
	{field: deploymentTextField(deploymentTextFieldOptions{label: "Azure OpenAI API Version", deploymentID: "openai-azure", field: "api_version", indent: 1, optional: true}), visibility: deploymentFieldAzureContext},
	{field: deploymentModelMappingsField(deploymentModelMappingsFieldOptions{label: "Azure Model Mappings", deploymentID: "openai-azure", indent: 1, optional: true}), visibility: deploymentFieldAzureContext},
	{field: deploymentTextField(deploymentTextFieldOptions{label: "Anthropic Bedrock Region", deploymentID: "anthropic-bedrock", field: "region", indent: 1, optional: true}), visibility: deploymentFieldBedrockContext},
	{field: deploymentTextField(deploymentTextFieldOptions{label: "Anthropic Vertex Project", deploymentID: "anthropic-vertex", field: "project_id", indent: 1, optional: true}), visibility: deploymentFieldVertexContext},
	{field: deploymentTextField(deploymentTextFieldOptions{label: "Anthropic Vertex Region", deploymentID: "anthropic-vertex", field: "region", indent: 1, optional: true}), visibility: deploymentFieldVertexContext},
	{field: deploymentTextField(deploymentTextFieldOptions{label: "Gemini Vertex Project", deploymentID: "gemini-vertex", field: "project_id", indent: 1, optional: true}), visibility: deploymentFieldVertexContext},
	{field: deploymentTextField(deploymentTextFieldOptions{label: "Gemini Vertex Region", deploymentID: "gemini-vertex", field: "region", indent: 1, optional: true}), visibility: deploymentFieldVertexContext},
}

// deploymentTabFields returns Deployments tab rows with cloud-only fields shown
// only when the current config or environment makes that cloud context relevant.
func deploymentTabFields(cfg Config) []cfgField {
	return deploymentFieldsFromSpecs(deploymentFieldsFromSpecsOptions{cfg: cfg})
}

type deploymentFieldsFromSpecsOptions struct {
	cfg               Config
	includeContextual bool
}

func deploymentFieldsFromSpecs(opts deploymentFieldsFromSpecsOptions) []cfgField {
	fields := make([]cfgField, 0, len(cfgAPIKeyFieldSpecs))
	for _, spec := range cfgAPIKeyFieldSpecs {
		if !opts.includeContextual && !deploymentFieldVisible(deploymentFieldVisibleOptions{cfg: opts.cfg, visibility: spec.visibility}) {
			continue
		}
		fields = append(fields, spec.field)
	}
	return fields
}

type deploymentFieldVisibleOptions struct {
	cfg        Config
	visibility deploymentFieldVisibility
}

func deploymentFieldVisible(opts deploymentFieldVisibleOptions) bool {
	switch opts.visibility {
	case deploymentFieldAzureContext:
		return deploymentAPIKeyConfigured(deploymentAPIKeyConfiguredOptions{cfg: opts.cfg, deploymentID: "openai-azure"})
	case deploymentFieldBedrockContext:
		return deploymentBedrockCredentialsAvailable()
	case deploymentFieldVertexContext:
		return deploymentVertexCredentialsAvailable()
	default:
		return true
	}
}

type deploymentAPIKeyConfiguredOptions struct {
	cfg          Config
	deploymentID string
}

func deploymentAPIKeyConfigured(opts deploymentAPIKeyConfiguredOptions) bool {
	return strings.TrimSpace(opts.cfg.deploymentConfig(opts.deploymentID).APIKey) != ""
}

func deploymentBedrockCredentialsAvailable() bool {
	if strings.TrimSpace(os.Getenv("AWS_ACCESS_KEY_ID")) != "" &&
		strings.TrimSpace(os.Getenv("AWS_SECRET_ACCESS_KEY")) != "" {
		return true
	}
	return anyDeploymentEnvSet(deploymentBedrockCredentialEnv)
}

var deploymentBedrockCredentialEnv = []string{
	"AWS_PROFILE",
	"AWS_SHARED_CREDENTIALS_FILE",
	"AWS_CONFIG_FILE",
	"AWS_WEB_IDENTITY_TOKEN_FILE",
	"AWS_CONTAINER_CREDENTIALS_RELATIVE_URI",
	"AWS_CONTAINER_CREDENTIALS_FULL_URI",
}

func deploymentVertexCredentialsAvailable() bool {
	return anyDeploymentEnvSet(deploymentVertexCredentialEnv)
}

var deploymentVertexCredentialEnv = []string{
	"GOOGLE_APPLICATION_CREDENTIALS",
	"CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE",
	"GOOGLE_OAUTH_ACCESS_TOKEN",
}

func anyDeploymentEnvSet(names []string) bool {
	for _, name := range names {
		if strings.TrimSpace(os.Getenv(name)) != "" {
			return true
		}
	}
	return false
}

// deploymentTextFieldOptions is the parameter bundle for deploymentTextField.
type deploymentTextFieldOptions struct {
	label        string
	deploymentID string
	field        string
	secret       bool
	normalizeURL bool
	indent       int
	optional     bool
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
		label:    label,
		indent:   opts.indent,
		optional: opts.optional,
		get:      get,
		display: func(c Config) string {
			if secret {
				return display(c)
			}
			return get(c)
		},
		secret: secret,
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
	indent       int
	optional     bool
}

func deploymentModelMappingsField(opts deploymentModelMappingsFieldOptions) cfgField {
	label, deploymentID := opts.label, opts.deploymentID
	return cfgField{
		label:    label,
		indent:   opts.indent,
		optional: opts.optional,
		get:      func(c Config) string { return formatStringMap(c.deploymentConfigs()[deploymentID].ModelMappings) },
		display:  func(c Config) string { return formatStringMap(c.deploymentConfigs()[deploymentID].ModelMappings) },
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
	return apiKeyRowForProviderInFields(apiKeyRowForProviderInFieldsOptions{provider: provider, fields: deploymentTabFields(Config{})})
}

type apiKeyRowForProviderInFieldsOptions struct {
	provider string
	fields   []cfgField
}

func apiKeyRowForProviderInFields(opts apiKeyRowForProviderInFieldsOptions) int {
	label := apiKeyLabelForProvider(opts.provider)
	for i, field := range opts.fields {
		if field.label == label {
			return i
		}
	}
	return 0
}

func apiKeyLabelForProvider(provider string) string {
	switch provider {
	case ProviderAnthropic:
		return "Anthropic API Key"
	case ProviderOpenAI:
		return "OpenAI API Key"
	case ProviderGrok:
		return "Grok API Key"
	case ProviderOpenRouter:
		return "OpenRouter API Key"
	case ProviderGemini:
		return "Gemini API Key"
	case ProviderOllama:
		return "Ollama Base URL"
	default:
		return ""
	}
}
