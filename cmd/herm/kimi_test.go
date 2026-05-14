package main

import (
	"testing"
)

// --- Config integration tests for Kimi provider ---

func TestConfiguredProviders_IncludesKimi(t *testing.T) {
	cfg := Config{KimiAPIKey: "test-key"}
	providers := cfg.configuredProviders()
	if !providers[ProviderKimi] {
		t.Error("expected Kimi in configured providers when API key is set")
	}
}

func TestConfiguredProviders_ExcludesKimiWithoutKey(t *testing.T) {
	cfg := Config{}
	providers := cfg.configuredProviders()
	if providers[ProviderKimi] {
		t.Error("expected Kimi excluded from configured providers when API key is empty")
	}
}

func TestDefaultLangdagProvider_Kimi(t *testing.T) {
	cfg := Config{KimiAPIKey: "test-key"}
	if got := cfg.defaultLangdagProvider(); got != ProviderKimi {
		t.Errorf("defaultLangdagProvider() = %q, want %q", got, ProviderKimi)
	}
}

func TestDefaultLangdagProvider_KimiFallsAfterOpenRouter(t *testing.T) {
	cfg := Config{
		OpenRouterAPIKey: "or-key",
		KimiAPIKey:       "kimi-key",
	}
	if got := cfg.defaultLangdagProvider(); got != ProviderOpenRouter {
		t.Errorf("defaultLangdagProvider() = %q, want %q (OpenRouter has higher priority)", got, ProviderOpenRouter)
	}
}

func TestDefaultLangdagProvider_KimiBeforeGemini(t *testing.T) {
	cfg := Config{
		KimiAPIKey:   "kimi-key",
		GeminiAPIKey: "gemini-key",
	}
	if got := cfg.defaultLangdagProvider(); got != ProviderKimi {
		t.Errorf("defaultLangdagProvider() = %q, want %q (Kimi has higher priority than Gemini)", got, ProviderKimi)
	}
}

func TestAvailableModels_FiltersToKimi(t *testing.T) {
	cfg := Config{KimiAPIKey: "test-key"}
	models := []ModelDef{
		{Provider: ProviderKimi, ID: "moonshot-v1-8k"},
		{Provider: ProviderAnthropic, ID: "claude-sonnet-4-6"},
		{Provider: ProviderKimi, ID: "moonshot-v1-128k"},
	}
	available := cfg.availableModels(models)
	if len(available) != 2 {
		t.Fatalf("expected 2 available models, got %d", len(available))
	}
	for _, m := range available {
		if m.Provider != ProviderKimi {
			t.Errorf("expected only Kimi models, got provider %q", m.Provider)
		}
	}
}

func TestNewLangdagClientForProvider_Kimi(t *testing.T) {
	cfg := Config{KimiAPIKey: "test-key"}
	client, err := newLangdagClientForProvider(newLangdagClientForProviderOptions{
		cfg:      cfg,
		provider: ProviderKimi,
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if client == nil {
		t.Fatal("expected non-nil client")
	}
}

func TestNewLangdagClient_SelectsKimi(t *testing.T) {
	cfg := Config{KimiAPIKey: "test-key"}
	client, err := newLangdagClient(cfg)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if client == nil {
		t.Fatal("expected non-nil client when Kimi key is configured")
	}
}

func TestProviderKimiConstant(t *testing.T) {
	if ProviderKimi != "kimi" {
		t.Errorf("ProviderKimi = %q, want %q", ProviderKimi, "kimi")
	}
}

func TestSupportedProviders_ContainsKimi(t *testing.T) {
	found := false
	for _, p := range supportedProviders {
		if p == ProviderKimi {
			found = true
			break
		}
	}
	if !found {
		t.Error("expected ProviderKimi in supportedProviders")
	}
}
