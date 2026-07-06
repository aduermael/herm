package main

import (
	"testing"
	"time"
)

// modelWithoutConfiguredProvider is a catalog model whose provider has no
// configured deployment, so it never makes a provider resolvable on its own.
func modelWithoutConfiguredProvider() []ModelDef {
	return []ModelDef{{ID: "some-model", Provider: ProviderAnthropic}}
}

func TestHeadlessProviderResolutionSettled(t *testing.T) {
	appleRuntimeModels := []ModelDef{{
		ID:                "apple-fm-runtime",
		Provider:          ProviderApple,
		RuntimeDiscovered: true,
		Deployments:       []ModelDeploymentDef{{DeploymentID: "apple-local"}},
	}}

	cases := []struct {
		name string
		app  *App
		want bool
	}{
		{
			name: "no provider, all discovery done",
			app: &App{
				config:       Config{},
				configReady:  true,
				models:       modelWithoutConfiguredProvider(),
				appleFetched: true,
			},
			want: true,
		},
		{
			name: "config not ready yet",
			app: &App{
				config:       Config{},
				configReady:  false,
				models:       modelWithoutConfiguredProvider(),
				appleFetched: true,
			},
			want: false,
		},
		{
			name: "model catalog not loaded yet",
			app: &App{
				config:       Config{},
				configReady:  true,
				models:       nil,
				appleFetched: true,
			},
			want: false,
		},
		{
			name: "apple discovery still in flight",
			app: &App{
				config:       Config{},
				configReady:  true,
				models:       modelWithoutConfiguredProvider(),
				appleFetched: false,
			},
			want: false,
		},
		{
			name: "ollama configured without key must not fast-fail",
			app: &App{
				config:        Config{Deployments: map[string]DeploymentConfig{"ollama-local": {BaseURL: "http://localhost:11434"}}},
				configReady:   true,
				models:        modelWithoutConfiguredProvider(),
				appleFetched:  true,
				ollamaFetched: true,
			},
			want: false,
		},
		{
			name: "ollama configured but discovery still in flight",
			app: &App{
				config:        Config{Deployments: map[string]DeploymentConfig{"ollama-local": {BaseURL: "http://localhost:11434"}}},
				configReady:   true,
				models:        modelWithoutConfiguredProvider(),
				appleFetched:  true,
				ollamaFetched: false,
			},
			want: false,
		},
		{
			name: "apple runtime models discovered (client refresh pending) must not fast-fail",
			app: &App{
				config:       Config{},
				configReady:  true,
				models:       appleRuntimeModels,
				appleFetched: true,
			},
			want: false,
		},
	}

	for _, tt := range cases {
		t.Run(tt.name, func(t *testing.T) {
			if got := tt.app.headlessProviderResolutionSettled(); got != tt.want {
				t.Fatalf("headlessProviderResolutionSettled() = %v, want %v", got, tt.want)
			}
		})
	}
}

// TestWaitHeadlessReadyNoProviderFailsFast drives waitHeadlessReady in the
// no-provider state and asserts it returns the actionable "no API key" error
// promptly, rather than blocking until the 60s initialization timeout.
func TestWaitHeadlessReadyNoProviderFailsFast(t *testing.T) {
	app := &App{
		config:       Config{},
		configReady:  true,
		models:       modelWithoutConfiguredProvider(),
		appleFetched: true,
		backend:      backendNaked,
		nakedReady:   true,
		resultCh:     make(chan any, 1),
	}
	// Drive one loop iteration; the empty message leaves langdagClient nil so
	// the fast-fail check fires.
	app.resultCh <- langdagReadyMsg{}

	type outcome struct{ err error }
	done := make(chan outcome, 1)
	go func() { done <- outcome{err: app.waitHeadlessReady()} }()

	select {
	case res := <-done:
		if res.err == nil {
			t.Fatal("expected error for missing provider, got nil")
		}
		if res.err.Error() != "no API key configured" {
			t.Fatalf("error = %q, want %q (fast-fail, not timeout)", res.err.Error(), "no API key configured")
		}
	case <-time.After(10 * time.Second):
		t.Fatal("waitHeadlessReady did not fail fast — it appears to have blocked on the 60s timeout")
	}
}
