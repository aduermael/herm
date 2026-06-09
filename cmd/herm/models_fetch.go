// models_fetch.go fetches model metadata from live provider APIs and normalizes it for menus.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"runtime"
	"strconv"
	"strings"
	"time"

	"langdag.com/langdag/types"
)

var runtimeGOOS = func() string { return runtime.GOOS }

// fetchOllamaModels fetches available models from an Ollama instance.
// Returns nil if the Ollama server is unreachable or no baseURL is configured.
func fetchOllamaModels(baseURL string) []ModelDef {
	if baseURL == "" {
		return nil
	}

	client := &http.Client{Timeout: 5 * time.Second}
	base := strings.TrimRight(baseURL, "/")

	resp, err := client.Get(base + "/api/tags")
	if err != nil {
		return nil
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil
	}

	var tagsResp struct {
		Models []struct {
			Name string `json:"name"`
		} `json:"models"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&tagsResp); err != nil {
		return nil
	}

	type result struct {
		idx   int
		model ModelDef
	}
	ch := make(chan result, len(tagsResp.Models))
	for i, m := range tagsResp.Models {
		i, m := i, m
		go func() {
			canonicalID := ollamaCanonicalModelID(m.Name)
			ch <- result{i, ModelDef{
				Provider:        ProviderOllama,
				OwnerProvider:   ProviderOllama,
				ID:              canonicalID,
				CanonicalID:     canonicalID,
				PromptPrice:     0,
				CompletionPrice: 0,
				PricingStatus:   types.CostStatusFree,
				PricingCurrency: "USD",
				PricingRatesPer1M: map[string]float64{
					"input_tokens":  0,
					"output_tokens": 0,
				},
				PriceLabel:     "free",
				ContextWindow:  ollamaContextWindow(ollamaContextWindowOptions{client: client, baseURL: base, modelName: m.Name}),
				NativeModelIDs: []string{m.Name},
				Deployments: []ModelDeploymentDef{{
					DeploymentID:  "ollama-local",
					ProviderID:    ProviderOllama,
					APIProtocolID: "openai-chat-completions",
					OfferingID:    "ollama-local:" + m.Name,
					NativeModelID: m.Name,
					PricingSnapshot: types.PricingSnapshot{
						Status:     types.CostStatusFree,
						Currency:   "USD",
						Source:     types.CostSourceCatalog,
						RatesPer1M: map[string]float64{"input_tokens": 0, "output_tokens": 0},
					},
				}},
			}}
		}()
	}
	models := make([]ModelDef, len(tagsResp.Models))
	for range tagsResp.Models {
		r := <-ch
		models[r.idx] = r.model
	}
	return models
}

const openRouterDefaultBase = "https://openrouter.ai/api/v1"
const openRouterReferer = "https://github.com/aduermael/herm"

// fetchOpenRouterOptions is the parameter bundle for fetchOpenRouterModelsFrom.
type fetchOpenRouterOptions struct {
	apiKey  string
	baseURL string
}

// fetchOpenRouterModels fetches available models from the OpenRouter API.
// Returns nil if apiKey is empty or the request fails.
func fetchOpenRouterModels(apiKey string) []ModelDef {
	return fetchOpenRouterModelsFrom(fetchOpenRouterOptions{apiKey: apiKey, baseURL: openRouterDefaultBase})
}

// fetchOpenRouterModelsFrom fetches models using the given base URL.
func fetchOpenRouterModelsFrom(opts fetchOpenRouterOptions) []ModelDef {
	apiKey, baseURL := opts.apiKey, opts.baseURL
	if apiKey == "" {
		return nil
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	client := &http.Client{}
	req, err := http.NewRequestWithContext(ctx, "GET", baseURL+"/models", nil)
	if err != nil {
		return nil
	}
	req.Header.Set("Authorization", "Bearer "+apiKey)
	req.Header.Set("HTTP-Referer", openRouterReferer)
	req.Header.Set("X-Title", "herm")

	resp, err := client.Do(req)
	if err != nil {
		return nil
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil
	}

	var body struct {
		Data []struct {
			ID            string `json:"id"`
			Name          string `json:"name"`
			ContextLength int    `json:"context_length"`
			Pricing       struct {
				Prompt     string `json:"prompt"`
				Completion string `json:"completion"`
			} `json:"pricing"`
			TopProvider struct {
				MaxCompletionTokens int `json:"max_completion_tokens"`
			} `json:"top_provider"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return nil
	}

	models := make([]ModelDef, 0, len(body.Data))
	for _, m := range body.Data {
		var promptPrice, completionPrice float64
		pricingStatus := types.CostStatusKnown
		// Prices are per-token strings; convert to per-million
		if p, err := strconv.ParseFloat(m.Pricing.Prompt, 64); err == nil {
			promptPrice = p * 1_000_000
		} else {
			pricingStatus = types.CostStatusUnknown
		}
		if p, err := strconv.ParseFloat(m.Pricing.Completion, 64); err == nil {
			completionPrice = p * 1_000_000
		} else {
			pricingStatus = types.CostStatusUnknown
		}
		if strings.Contains(m.ID, ":free") || (pricingStatus == types.CostStatusKnown && promptPrice == 0 && completionPrice == 0) {
			pricingStatus = types.CostStatusFree
		}
		ownerProvider := ownerProviderFromCanonicalID(m.ID)
		if ownerProvider == "" {
			ownerProvider = ProviderOpenRouter
		}
		priceLabel := formatPricePerM(formatPricePerMOptions{promptPrice: promptPrice, completionPrice: completionPrice})
		if pricingStatus == types.CostStatusFree {
			priceLabel = "free"
		} else if pricingStatus == types.CostStatusUnknown {
			priceLabel = "unknown"
		}
		rates := map[string]float64{"input_tokens": promptPrice, "output_tokens": completionPrice}
		if pricingStatus == types.CostStatusUnknown {
			rates = nil
		}
		models = append(models, ModelDef{
			Provider:          ProviderOpenRouter,
			OwnerProvider:     ownerProvider,
			ID:                m.ID,
			CanonicalID:       m.ID,
			PromptPrice:       promptPrice,
			CompletionPrice:   completionPrice,
			PricingStatus:     pricingStatus,
			PricingCurrency:   "USD",
			PricingRatesPer1M: rates,
			PriceLabel:        priceLabel,
			ContextWindow:     m.ContextLength,
			NativeModelIDs:    []string{m.ID},
			Deployments: []ModelDeploymentDef{{
				DeploymentID:  "openrouter",
				ProviderID:    ProviderOpenRouter,
				APIProtocolID: "openai-chat-completions",
				OfferingID:    "openrouter:" + m.ID,
				NativeModelID: m.ID,
				PricingSnapshot: types.PricingSnapshot{
					Status:     pricingStatus,
					Currency:   "USD",
					Source:     types.CostSourceCatalog,
					RatesPer1M: rates,
				},
			}},
		})
	}
	return models
}

type fetchAppleModelsOptions struct {
	baseURL string
}

func fetchAppleModels(baseURL string) []ModelDef {
	return fetchAppleModelsFrom(fetchAppleModelsOptions{baseURL: baseURL})
}

func fetchAppleModelsFrom(opts fetchAppleModelsOptions) []ModelDef {
	if runtimeGOOS() != "darwin" {
		return nil
	}
	baseURL := strings.TrimRight(opts.baseURL, "/")
	if baseURL == "" {
		baseURL = appleFMDefaultBaseURL
	}
	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Get(baseURL + "/health")
	if err != nil {
		return nil
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil
	}
	var health struct {
		Status string `json:"status"`
		Models []struct {
			ID        string `json:"id"`
			Name      string `json:"name"`
			Available bool   `json:"available"`
		} `json:"models"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&health); err != nil {
		return nil
	}
	if health.Status != "fm serve is running" {
		return nil
	}
	names := map[string]string{
		"system": "Apple system",
		"pcc":    "Apple Private Cloud Compute",
	}
	var models []ModelDef
	for _, model := range health.Models {
		modelID := appleHealthModelID(appleHealthModelIDOptions{id: model.ID, name: model.Name})
		name, expected := names[modelID]
		if !expected || !model.Available {
			continue
		}
		canonicalID := ProviderApple + "/" + modelID
		models = append(models, ModelDef{
			Provider:          ProviderApple,
			OwnerProvider:     ProviderApple,
			ID:                canonicalID,
			CanonicalID:       canonicalID,
			Label:             name,
			RuntimeDiscovered: true,
			PromptPrice:       0,
			CompletionPrice:   0,
			PricingStatus:     types.CostStatusFree,
			PricingCurrency:   "USD",
			PricingRatesPer1M: map[string]float64{
				"input_tokens":  0,
				"output_tokens": 0,
			},
			PriceLabel:     "free",
			NativeModelIDs: []string{modelID},
			Deployments: []ModelDeploymentDef{{
				DeploymentID:  "apple-local",
				ProviderID:    ProviderApple,
				APIProtocolID: "openai-chat-completions",
				OfferingID:    "apple-local:" + modelID,
				NativeModelID: modelID,
				PricingSnapshot: types.PricingSnapshot{
					Status:     types.CostStatusFree,
					Currency:   "USD",
					Source:     types.CostSourceCatalog,
					RatesPer1M: map[string]float64{"input_tokens": 0, "output_tokens": 0},
				},
			}},
		})
	}
	return models
}

type appleHealthModelIDOptions struct {
	id   string
	name string
}

func appleHealthModelID(opts appleHealthModelIDOptions) string {
	if opts.name != "" {
		return opts.name
	}
	return opts.id
}

func ollamaCanonicalModelID(modelID string) string {
	if modelID == "" || strings.HasPrefix(modelID, ProviderOllama+"/") {
		return modelID
	}
	return ProviderOllama + "/" + modelID
}

// ollamaContextWindowOptions is the parameter bundle for ollamaContextWindow.
type ollamaContextWindowOptions struct {
	client    *http.Client
	baseURL   string
	modelName string
}

// ollamaContextWindow queries /api/show for the model's actual context length.
// Returns 0 if the server doesn't provide it.
func ollamaContextWindow(opts ollamaContextWindowOptions) int {
	client, baseURL, modelName := opts.client, opts.baseURL, opts.modelName
	body, _ := json.Marshal(map[string]string{"model": modelName})
	resp, err := client.Post(baseURL+"/api/show", "application/json", bytes.NewReader(body))
	if err != nil || resp.StatusCode != http.StatusOK {
		return 0
	}
	defer resp.Body.Close()

	// model_info contains keys like "llama.context_length", "gemma3.context_length", etc.
	var showResp struct {
		ModelInfo map[string]json.RawMessage `json:"model_info"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&showResp); err != nil {
		return 0
	}
	for key, val := range showResp.ModelInfo {
		if strings.HasSuffix(key, ".context_length") {
			var n int
			if err := json.Unmarshal(val, &n); err == nil && n > 0 {
				return n
			}
		}
	}
	return 0
}
