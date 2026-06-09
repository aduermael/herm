// apple_runtime.go contains runtime-discovered Apple model routing helpers.
package main

import "sort"

func hasRuntimeAppleModels(models []ModelDef) bool {
	return len(runtimeAppleModelIDs(models)) > 0
}

func runtimeAppleModelIDs(models []ModelDef) []string {
	seen := map[string]bool{}
	var ids []string
	for _, model := range models {
		if !runtimeAppleModel(model) {
			continue
		}
		for _, id := range []string{model.ID, model.CanonicalID} {
			if id == "" || seen[id] {
				continue
			}
			seen[id] = true
			ids = append(ids, id)
		}
	}
	sort.Strings(ids)
	return ids
}

func runtimeAppleModel(model ModelDef) bool {
	if !model.RuntimeDiscovered {
		return false
	}
	if model.Provider == ProviderApple || model.OwnerProvider == ProviderApple {
		return true
	}
	for _, deployment := range model.Deployments {
		if deployment.DeploymentID == "apple-local" {
			return true
		}
	}
	return false
}

type routingPolicyWithRuntimeApplePinsOptions struct {
	policy        *RoutingPolicy
	appleModelIDs []string
}

func routingPolicyWithRuntimeApplePins(opts routingPolicyWithRuntimeApplePinsOptions) *RoutingPolicy {
	if len(opts.appleModelIDs) == 0 {
		return opts.policy
	}
	pinned := cloneRoutingPolicy(opts.policy)
	if pinned == nil {
		pinned = &RoutingPolicy{}
	}
	if pinned.Models == nil {
		pinned.Models = map[string][]RoutingStage{}
	}
	for _, modelID := range opts.appleModelIDs {
		pinned.Models[modelID] = []RoutingStage{{
			Deployments: []DeploymentChoice{{DeploymentID: "apple-local", Weight: 100}},
		}}
	}
	return pinned
}
