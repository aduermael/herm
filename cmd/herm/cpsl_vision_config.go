// cpsl_vision_config.go resolves vision models and configures the CPSL worker.
package main

import (
	"context"
	"log"
	"time"
)

func (a *App) configureCPSLVision() {
	if !a.cpslReady || a.cpslWorker == nil || a.models == nil || a.modelCatalog == nil {
		return
	}
	worker := a.cpslWorker
	config := cpslVisionRuntimeConfig{
		Model:   a.config.resolveVisionModel(a.models),
		Config:  a.config,
		Catalog: a.modelCatalog,
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		if err := worker.ConfigureVision(ctx, config); err != nil {
			log.Printf("warning: configuring CPSL vision model: %v", err)
		}
	}()
}

// resolveVisionModel returns the model used by CPSL vision document reads.
// Vision is optional in config and follows the active model when unset.
func (c Config) resolveVisionModel(models []ModelDef) string {
	return c.resolveVisionModelResult(models).ResolvedModelID
}

func (c Config) resolveVisionModelResult(models []ModelDef) configuredModelResolution {
	if c.VisionModel == "" {
		return configuredModelResolution{ResolvedModelID: c.resolveActiveModel(models)}
	}
	available := c.availableModels(models)
	lookup := c.lookupConfiguredModelID(lookupConfiguredModelIDOptions{modelID: c.VisionModel, smartDefault: defaultCanonicalVisionModel, available: available, models: models})
	if lookup.Status == configuredModelUsable {
		return lookup
	}
	fallback := c.resolveActiveModel(models)
	return configuredModelResolution{
		ConfiguredModelID: c.VisionModel,
		ResolvedModelID:   fallback,
		Fallback:          true,
		Status:            lookup.Status,
		Diagnostic:        configuredModelDiagnostic(configuredModelDiagnosticOptions{field: "vision_model", configured: c.VisionModel, fallback: fallback, status: lookup.Status}),
	}
}
