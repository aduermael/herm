package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

// --- fetchKimiModels tests ---

func TestFetchKimiModelsEmptyKey(t *testing.T) {
	models := fetchKimiModels("")
	if models != nil {
		t.Errorf("expected nil for empty API key, got %d models", len(models))
	}
}

func TestFetchKimiModelsSuccess(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/models" {
			http.NotFound(w, r)
			return
		}
		json.NewEncoder(w).Encode(map[string]any{
			"data": []map[string]any{
				{
					"id":             "moonshot-v1-8k",
					"object":         "model",
					"context_length": 8192,
				},
				{
					"id":             "moonshot-v1-128k",
					"object":         "model",
					"context_length": 131072,
				},
			},
		})
	}))
	defer srv.Close()

	// Override the default base URL for testing
	origBase := kimiDefaultBase
	defer func() {
		if origBase != kimiDefaultBase {
			t.Error("kimiDefaultBase was mutated")
		}
	}()

	models := fetchKimiModelsFrom(fetchKimiOptions{apiKey: "test-key", baseURL: srv.URL})
	if len(models) != 2 {
		t.Fatalf("expected 2 models, got %d", len(models))
	}
	if models[0].Provider != ProviderKimi {
		t.Errorf("Provider = %q, want %q", models[0].Provider, ProviderKimi)
	}
	if models[0].ID != "moonshot-v1-8k" {
		t.Errorf("ID = %q, want moonshot-v1-8k", models[0].ID)
	}
	if models[0].ContextWindow != 8192 {
		t.Errorf("ContextWindow = %d, want 8192", models[0].ContextWindow)
	}
	if models[1].ContextWindow != 131072 {
		t.Errorf("ContextWindow = %d, want 131072", models[1].ContextWindow)
	}
}

func TestFetchKimiModelsServerError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "internal error", http.StatusInternalServerError)
	}))
	defer srv.Close()

	models := fetchKimiModelsFrom(fetchKimiOptions{apiKey: "test-key", baseURL: srv.URL})
	if models != nil {
		t.Errorf("expected nil on server error, got %d models", len(models))
	}
}

func TestFetchKimiModelsInvalidJSON(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("not json"))
	}))
	defer srv.Close()

	models := fetchKimiModelsFrom(fetchKimiOptions{apiKey: "test-key", baseURL: srv.URL})
	if models != nil {
		t.Errorf("expected nil on invalid JSON, got %d models", len(models))
	}
}

func TestFetchKimiModelsUnreachable(t *testing.T) {
	models := fetchKimiModelsFrom(fetchKimiOptions{apiKey: "test-key", baseURL: "http://127.0.0.1:1"})
	if models != nil {
		t.Errorf("expected nil for unreachable server, got %d models", len(models))
	}
}

func TestFetchKimiModelsEmpty(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(map[string]any{"data": []any{}})
	}))
	defer srv.Close()

	models := fetchKimiModelsFrom(fetchKimiOptions{apiKey: "test-key", baseURL: srv.URL})
	if len(models) != 0 {
		t.Errorf("expected 0 models for empty list, got %d", len(models))
	}
}

func TestFetchKimiModelsAuthHeader(t *testing.T) {
	var gotAuth string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		json.NewEncoder(w).Encode(map[string]any{"data": []any{}})
	}))
	defer srv.Close()

	fetchKimiModelsFrom(fetchKimiOptions{apiKey: "my-api-key", baseURL: srv.URL})
	if gotAuth != "Bearer my-api-key" {
		t.Errorf("Authorization = %q, want %q", gotAuth, "Bearer my-api-key")
	}
}

func TestFetchKimiModelsProviderField(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(map[string]any{
			"data": []map[string]any{
				{"id": "moonshot-v1-32k", "context_length": 32768},
			},
		})
	}))
	defer srv.Close()

	models := fetchKimiModelsFrom(fetchKimiOptions{apiKey: "test-key", baseURL: srv.URL})
	if len(models) != 1 {
		t.Fatalf("expected 1 model, got %d", len(models))
	}
	if models[0].Provider != ProviderKimi {
		t.Errorf("Provider = %q, want %q", models[0].Provider, ProviderKimi)
	}
}

func TestFetchKimiModelsMissingContextLength(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(map[string]any{
			"data": []map[string]any{
				{"id": "moonshot-v1-auto"},
			},
		})
	}))
	defer srv.Close()

	models := fetchKimiModelsFrom(fetchKimiOptions{apiKey: "test-key", baseURL: srv.URL})
	if len(models) != 1 {
		t.Fatalf("expected 1 model, got %d", len(models))
	}
	if models[0].ContextWindow != 0 {
		t.Errorf("ContextWindow = %d, want 0 when context_length is missing", models[0].ContextWindow)
	}
}
