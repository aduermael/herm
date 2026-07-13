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
