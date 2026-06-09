// configeditor_routing_fields.go keeps routing field helpers for the
// interactive config editor separate from general editor key handling.
package main

func (a *App) routingTabFields() []cfgField {
	fields := []cfgField{{
		label:     "Add rule",
		valueless: true,
		action:    func(a *App) { a.openRoutingAddRuleScopeMenu() },
	}}
	for _, item := range routingRuleMenuItems(a.cfgDraft.Routing) {
		item := item
		fields = append(fields, cfgField{
			label: item.label,
			get: func(c Config) string {
				return routingScopedStagesSummary(getRoutingStages(getRoutingStagesOptions{policy: c.Routing, scope: item.scope, key: item.key})) + "."
			},
			action: func(a *App) { a.openRoutingRuleOptionsMenu(item) },
		})
	}
	return fields
}

type routingScope string

const (
	routingScopeDefault  routingScope = "default"
	routingScopeProvider routingScope = "provider"
	routingScopeModel    routingScope = "model"
)

// routingStagesFieldOptions is the parameter bundle for (*App).routingStagesField.
type routingStagesFieldOptions struct {
	label string
	scope routingScope
	key   string
}

func (a *App) routingStagesField(opts routingStagesFieldOptions) cfgField {
	label, scope, key := opts.label, opts.scope, opts.key
	return cfgField{
		label: label,
		get: func(c Config) string {
			if c.Routing == nil {
				return ""
			}
			return formatRoutingStages(getRoutingStages(getRoutingStagesOptions{policy: c.Routing, scope: scope, key: key}))
		},
		set: func(c *Config, v string) {
			stages, err := parseRoutingStages(v)
			if err != nil {
				a.messages = append(a.messages, chatMessage{kind: msgError, content: "Invalid routing: " + err.Error()})
				return
			}
			setRoutingStages(setRoutingStagesOptions{cfg: c, scope: scope, key: key, stages: stages})
		},
	}
}

// getRoutingStagesOptions is the parameter bundle for getRoutingStages.
type getRoutingStagesOptions struct {
	policy *RoutingPolicy
	scope  routingScope
	key    string
}

func getRoutingStages(opts getRoutingStagesOptions) []RoutingStage {
	policy, scope, key := opts.policy, opts.scope, opts.key
	if policy == nil {
		return nil
	}
	switch scope {
	case routingScopeDefault:
		return policy.Default
	case routingScopeProvider:
		return policy.Providers[key]
	case routingScopeModel:
		return policy.Models[key]
	default:
		return nil
	}
}

// setRoutingStagesOptions is the parameter bundle for setRoutingStages.
type setRoutingStagesOptions struct {
	cfg    *Config
	scope  routingScope
	key    string
	stages []RoutingStage
}

func setRoutingStages(opts setRoutingStagesOptions) {
	c, scope, key, stages := opts.cfg, opts.scope, opts.key, opts.stages
	if c.Routing == nil {
		c.Routing = &RoutingPolicy{}
	}
	switch scope {
	case routingScopeDefault:
		c.Routing.Default = stages
	case routingScopeProvider:
		if len(stages) == 0 {
			delete(c.Routing.Providers, key)
		} else {
			if c.Routing.Providers == nil {
				c.Routing.Providers = map[string][]RoutingStage{}
			}
			c.Routing.Providers[key] = stages
		}
	case routingScopeModel:
		if len(stages) == 0 {
			delete(c.Routing.Models, key)
		} else {
			if c.Routing.Models == nil {
				c.Routing.Models = map[string][]RoutingStage{}
			}
			c.Routing.Models[key] = stages
		}
	}
	c.Routing = cloneRoutingPolicy(c.Routing)
}

func (a *App) routingControlsVisible(cfg Config) bool {
	return len(eligibleDeploymentIDsForConfigModels(eligibleDeploymentIDsForConfigModelsOptions{cfg: cfg, models: a.models})) >= 2 ||
		!routingPolicyIsEmpty(cfg.Routing)
}

// eligibleDeploymentIDsForConfigModelsOptions is the parameter bundle for eligibleDeploymentIDsForConfigModels.
type eligibleDeploymentIDsForConfigModelsOptions struct {
	cfg    Config
	models []ModelDef
}

func eligibleDeploymentIDsForConfigModels(opts eligibleDeploymentIDsForConfigModelsOptions) map[string]bool {
	cfg, models := opts.cfg, opts.models
	configured := cfg.configuredDeploymentIDs()
	deploymentConfigs := cfg.deploymentConfigs()
	eligible := map[string]bool{}
	for _, model := range models {
		modelConfigured := configuredDeploymentsForModel(configuredDeploymentsForModelOptions{base: configured, model: model})
		for _, deployment := range model.Deployments {
			if !modelConfigured[deployment.DeploymentID] {
				continue
			}
			if deployment.MappingRequired && deploymentConfigs[deployment.DeploymentID].ModelMappings[model.ID] == "" {
				continue
			}
			eligible[deployment.DeploymentID] = true
		}
	}
	if len(models) == 0 {
		for deploymentID := range configured {
			eligible[deploymentID] = true
		}
	}
	return eligible
}
