package main

import (
	"testing"

	"langdag.com/langdag"
)

func TestEnsureHermModelCatalogCompatibilityAddsGrok45(t *testing.T) {
	catalog := langdag.ReferenceCatalogV1()
	delete(catalog.Models, "xai/grok-4.5")
	catalog = ensureHermModelCatalogCompatibility(catalog)

	model := catalog.Models["xai/grok-4.5"]
	if model == nil || model.ContextWindow != 500_000 || model.ProviderID != "xai" {
		t.Fatalf("model = %#v", model)
	}
	if catalog.Aliases["grok-4.5"] != "xai/grok-4.5" {
		t.Fatalf("alias = %q", catalog.Aliases["grok-4.5"])
	}
	found := false
	for _, offering := range catalog.Offerings {
		if offering.CanonicalModelID == "xai/grok-4.5" && offering.DeploymentID == "grok-direct" && offering.NativeModelID == "grok-4.5" {
			found = true
		}
	}
	if !found {
		t.Fatal("missing grok-direct Grok 4.5 offering")
	}
	models := modelsFromCatalog(catalog)
	cfg := Config{GrokAPIKey: "xai-test", VisionModel: "xai/grok-4.5"}
	if got := cfg.resolveVisionModel(models); got != "xai/grok-4.5" {
		t.Fatalf("resolveVisionModel = %q, want xai/grok-4.5", got)
	}
}

func TestEnsureHermModelCatalogCompatibilityKeepsPublishedEntry(t *testing.T) {
	catalog := langdag.ReferenceCatalogV1()
	catalog.Models["xai/grok-4.5"] = &langdag.ModelV1{ID: "xai/grok-4.5", Name: "Published"}
	offeringCount := len(catalog.Offerings)
	ensureHermModelCatalogCompatibility(catalog)
	if catalog.Models["xai/grok-4.5"].Name != "Published" || len(catalog.Offerings) != offeringCount {
		t.Fatal("published catalog entry should win")
	}
}
