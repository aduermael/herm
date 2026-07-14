// model_catalog_compat.go supplies short-lived model metadata compatibility entries.
package main

import (
	"time"

	"langdag.com/langdag"
)

// ensureHermModelCatalogCompatibility fills the short release window between
// a provider launching a model and the next published LangDAG catalog snapshot.
// Entries already supplied by LangDAG always win.
func ensureHermModelCatalogCompatibility(catalog *langdag.ModelCatalog) *langdag.ModelCatalog {
	if catalog == nil {
		return nil
	}
	const canonicalID = "xai/grok-4.5"
	if catalog.Models[canonicalID] != nil {
		return catalog
	}
	if catalog.Models == nil {
		catalog.Models = make(map[string]*langdag.ModelV1)
	}
	catalog.Models[canonicalID] = &langdag.ModelV1{
		ID:            canonicalID,
		ProviderID:    "xai",
		Name:          "Grok 4.5",
		Family:        "grok-4.5",
		ContextWindow: 500_000,
	}
	effectiveAt := time.Date(2026, time.July, 8, 0, 0, 0, 0, time.UTC)
	catalog.Offerings = append(catalog.Offerings, langdag.ModelOfferingV1{
		ID:               "grok-direct:grok-4.5",
		CanonicalModelID: canonicalID,
		DeploymentID:     "grok-direct",
		NativeModelID:    "grok-4.5",
		Pricing: langdag.PricingV1{
			Status:      langdag.PricingKnown,
			Currency:    "USD",
			EffectiveAt: effectiveAt,
			RatesPer1M: map[string]float64{
				"input_tokens":            2,
				"cache_read_input_tokens": 0.5,
				"output_tokens":           6,
			},
		},
	})
	if catalog.Aliases == nil {
		catalog.Aliases = make(map[string]string)
	}
	catalog.Aliases["grok-4.5"] = canonicalID
	return catalog
}
