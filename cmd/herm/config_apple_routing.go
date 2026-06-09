// config_apple_routing.go adapts routing policy checks for live Apple models.
package main

type routingPolicyForModelOptions struct {
	policy *RoutingPolicy
	model  ModelDef
}

func routingPolicyForModel(opts routingPolicyForModelOptions) *RoutingPolicy {
	if opts.policy == nil || !runtimeAppleModel(opts.model) {
		return opts.policy
	}
	return routingPolicyWithRuntimeApplePins(routingPolicyWithRuntimeApplePinsOptions{
		policy:        opts.policy,
		appleModelIDs: runtimeAppleModelIDs([]ModelDef{opts.model}),
	})
}

type dynamicAppleDeploymentAvailableOptions struct {
	model      ModelDef
	deployment ModelDeploymentDef
}

func dynamicAppleDeploymentAvailable(opts dynamicAppleDeploymentAvailableOptions) bool {
	return opts.model.RuntimeDiscovered &&
		opts.deployment.DeploymentID == "apple-local" &&
		(opts.model.Provider == ProviderApple || opts.model.OwnerProvider == ProviderApple)
}

type configuredDeploymentsForModelOptions struct {
	base  map[string]bool
	model ModelDef
}

func configuredDeploymentsForModel(opts configuredDeploymentsForModelOptions) map[string]bool {
	out := opts.base
	for _, deployment := range opts.model.Deployments {
		if dynamicAppleDeploymentAvailable(dynamicAppleDeploymentAvailableOptions{model: opts.model, deployment: deployment}) {
			out = cloneBoolMap(opts.base)
			if out == nil {
				out = map[string]bool{}
			}
			out["apple-local"] = true
			return out
		}
	}
	return out
}

type routingStructuralDiagnosticsForConfigModelsOptions struct {
	configModels configModelsOptions
	index        RoutingValidationIndex
}

func routingStructuralDiagnosticsForConfigModels(opts routingStructuralDiagnosticsForConfigModelsOptions) []RoutingDiagnostic {
	policy := opts.configModels.cfg.Routing
	if policy == nil {
		return nil
	}
	structural := RoutingPolicy{
		Default:   policy.Default,
		Providers: policy.Providers,
	}
	diagnostics := structural.validate(opts.index)
	for canonicalModelID, stages := range policy.Models {
		path := "routing.models." + canonicalModelID
		if !looksCanonicalModelID(canonicalModelID) {
			diagnostics = append(diagnostics, RoutingDiagnostic{Path: path, Code: "invalid_canonical_model_id", Message: "model route key must be an owner-qualified canonical model id"})
			continue
		}
		if modelRouteMatchesAnyModel(modelRouteMatchesAnyModelOptions{models: opts.configModels.models, canonicalModelID: canonicalModelID}) {
			continue
		}
		diagnostics = append(diagnostics, validateRoutingStages(validateRoutingStagesOptions{
			path:             path,
			canonicalModelID: canonicalModelID,
			stages:           stages,
			index:            opts.index,
		})...)
	}
	return diagnostics
}

type modelRouteMatchesAnyModelOptions struct {
	models           []ModelDef
	canonicalModelID string
}

func modelRouteMatchesAnyModel(opts modelRouteMatchesAnyModelOptions) bool {
	for _, model := range opts.models {
		if model.ID == opts.canonicalModelID || model.CanonicalID == opts.canonicalModelID {
			return true
		}
	}
	return false
}
