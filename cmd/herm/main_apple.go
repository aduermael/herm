// main_apple.go handles Apple model discovery messages and langdag readiness.
package main

import "log"

func (a *App) handleAppleModelsMsg(msg appleModelsMsg) {
	a.appleFetched = true
	base := modelsFromCatalog(a.modelCatalog)
	dynamic := dynamicModelsForProviders(dynamicModelsForProvidersOptions{
		models:    a.models,
		providers: map[string]bool{ProviderOllama: true, ProviderOpenRouter: true},
	})
	dynamic = append(dynamic, msg.models...)
	a.models = mergeDynamicModels(mergeDynamicModelsOptions{base: base, dynamic: dynamic})
	if a.sweLoaded && a.sweScores != nil {
		matchSWEScores(matchSWEScoresOptions{models: a.models, scores: a.sweScores})
	}
	alreadyShown := a.shownInitialModel
	a.maybeShowInitialModels()
	if alreadyShown {
		a.refreshResolvedModelDisplay()
	}
	provider := a.config.defaultLangdagProviderForModels(a.models)
	runtimeAppleAvailable := hasRuntimeAppleModels(a.models)
	shouldRefreshLangdag := hasRuntimeAppleModels(msg.models)
	if a.langdagRuntimeApple && !runtimeAppleAvailable {
		shouldRefreshLangdag = true
	}
	if !shouldRefreshLangdag && a.langdagProvider == ProviderApple && provider != ProviderApple {
		shouldRefreshLangdag = true
	}
	if shouldRefreshLangdag {
		models := a.models
		catalog := a.modelCatalog
		cfg := a.config
		go func() {
			client, err := newLangdagClientForModelsWithCatalog(newLangdagClientForModelsWithCatalogOptions{
				cfg:     cfg,
				models:  models,
				catalog: catalog,
			})
			a.resultCh <- langdagReadyMsg{client: client, provider: provider, runtimeApple: hasRuntimeAppleModels(models), err: err}
		}()
	}
}

func (a *App) handleDraftAppleModelsMsg(msg draftAppleModelsMsg) {
	if !a.cfgActive {
		return
	}
	base := modelsFromCatalog(a.modelCatalog)
	dynamic := dynamicModelsForProviders(dynamicModelsForProvidersOptions{
		models:    a.models,
		providers: map[string]bool{ProviderOllama: true, ProviderOpenRouter: true},
	})
	dynamic = append(dynamic, msg.models...)
	models := mergeDynamicModels(mergeDynamicModelsOptions{base: base, dynamic: dynamic})
	a.doOpenConfigModelPicker(doOpenConfigModelPickerOptions{models: models, getCurrentID: msg.getCurrentID, onSelect: msg.onSelect})
}

func (a *App) handleLangdagReadyMsg(msg langdagReadyMsg) {
	if msg.err != nil {
		log.Printf("warning: langdag init: %v", msg.err)
		return
	}
	if msg.client == nil && msg.provider == "" && a.langdagClient != nil {
		if a.langdagRuntimeApple && !hasRuntimeAppleModels(a.models) {
			oldClient := a.langdagClient
			a.langdagClient = nil
			a.langdagProvider = ""
			a.langdagRuntimeApple = false
			_ = oldClient.Close()
			log.Printf("warning: langdag init: no configured provider; cleared stale Apple runtime client")
			return
		}
		log.Printf("warning: langdag init: no configured provider; keeping existing %s client", a.langdagProvider)
		return
	}
	if msg.client != nil && !msg.runtimeApple && a.langdagClient != nil && a.langdagRuntimeApple && hasRuntimeAppleModels(a.models) {
		_ = msg.client.Close()
		log.Printf("warning: langdag init: ignoring stale %s client without Apple runtime routing", msg.provider)
		return
	}
	a.langdagClient = msg.client
	a.langdagProvider = msg.provider
	a.langdagRuntimeApple = msg.runtimeApple
}
