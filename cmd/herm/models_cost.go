// models_cost.go computes model usage costs and formats cost-related values for display.
package main

import (
	"fmt"
	"reflect"
	"sort"
	"strings"

	"langdag.com/langdag/types"
)

// computeCostOptions is the parameter bundle for computeCost.
type computeCostOptions struct {
	models  []ModelDef
	modelID string
	usage   types.Usage
}

// computeCost calculates the USD cost for a single LLM call based on token
// usage and model pricing. Prices are per million tokens. For Anthropic models,
// cache read tokens are charged at 10% of the input price.
// Returns 0 if the model is not found.
func computeCost(opts computeCostOptions) float64 {
	return computeCostResult(opts).Total
}

func computeCostResult(opts computeCostOptions) types.CostResult {
	matches := findModelsByID(findModelsByIDOptions{models: opts.models, id: opts.modelID})
	if len(matches) == 0 {
		return types.CostResult{
			Status:            types.CostStatusUnknown,
			Source:            types.CostSourceHistorical,
			MissingDimensions: []string{"model:" + opts.modelID},
		}
	}
	if len(matches) > 1 && !sameLegacyPricing(matches) {
		return types.CostResult{
			Status:            types.CostStatusUnknown,
			Source:            types.CostSourceHistorical,
			MissingDimensions: []string{"ambiguous_model_id:" + opts.modelID},
		}
	}
	m := matches[0]
	usage := opts.usage
	snapshot := pricingSnapshotForModel(m)
	if snapshot.Status == "" {
		snapshot.Status = inferCatalogPricingStatus(inferCatalogPricingStatusOptions{
			inputPrice:  m.PromptPrice,
			outputPrice: m.CompletionPrice,
			provider:    m.Provider,
			modelID:     m.ID,
		})
	}
	result := types.ComputeCostFromPricingSnapshot(snapshot, types.NormalizedUsageFromUsage(usage))
	if result.Source == "" {
		result.Source = types.CostSourceHistorical
	}
	return result
}

func sameLegacyPricing(matches []ModelDef) bool {
	if len(matches) < 2 {
		return true
	}
	first := comparablePricingSnapshotForModel(matches[0])
	for _, match := range matches[1:] {
		next := comparablePricingSnapshotForModel(match)
		if !reflect.DeepEqual(first, next) {
			return false
		}
	}
	return true
}

func comparablePricingSnapshotForModel(m ModelDef) types.PricingSnapshot {
	snapshot := pricingSnapshotForModel(m)
	if len(snapshot.RatesPer1M) == 0 {
		snapshot.RatesPer1M = nil
	}
	if len(snapshot.MissingDimensions) == 0 {
		snapshot.MissingDimensions = nil
	} else {
		sort.Strings(snapshot.MissingDimensions)
	}
	return snapshot
}

func pricingSnapshotForModel(m ModelDef) types.PricingSnapshot {
	if m.RouteDependentPricing {
		return types.PricingSnapshot{
			Status:            types.CostStatusUnknown,
			Currency:          defaultPricingCurrency(m.PricingCurrency),
			Source:            types.CostSourceCatalog,
			MissingDimensions: []string{"route_dependent_pricing:" + m.ID},
		}
	}
	rates := map[string]float64{}
	for k, v := range m.PricingRatesPer1M {
		rates[k] = v
	}
	if len(rates) == 0 {
		rates["input_tokens"] = m.PromptPrice
		rates["output_tokens"] = m.CompletionPrice
		if m.Provider == ProviderAnthropic && m.PromptPrice > 0 {
			rates["cache_read_input_tokens"] = m.PromptPrice * 0.1
		}
	}
	status := m.PricingStatus
	if status == "" {
		status = inferCatalogPricingStatus(inferCatalogPricingStatusOptions{
			inputPrice:  m.PromptPrice,
			outputPrice: m.CompletionPrice,
			provider:    m.Provider,
			modelID:     m.ID,
		})
	}
	if status == types.CostStatusUnknown {
		rates = nil
	}
	currency := defaultPricingCurrency(m.PricingCurrency)
	source := types.CostSourceHistorical
	if len(m.Deployments) > 0 {
		source = types.CostSourceCatalog
	}
	return types.PricingSnapshot{
		Status:            status,
		Currency:          currency,
		Source:            source,
		RatesPer1M:        rates,
		MissingDimensions: append([]string(nil), m.MissingPriceDimensions...),
	}
}

func defaultPricingCurrency(currency string) string {
	if currency == "" {
		return "USD"
	}
	return currency
}

// inferCatalogPricingStatusOptions is the parameter bundle for inferCatalogPricingStatus.
type inferCatalogPricingStatusOptions struct {
	inputPrice  float64
	outputPrice float64
	provider    string
	modelID     string
}

func inferCatalogPricingStatus(opts inferCatalogPricingStatusOptions) types.CostStatus {
	if strings.Contains(opts.modelID, ":free") || opts.provider == ProviderOllama || opts.provider == ProviderApple {
		return types.CostStatusFree
	}
	if opts.inputPrice == 0 && opts.outputPrice == 0 {
		return types.CostStatusUnknown
	}
	return types.CostStatusKnown
}

// formatCost formats a USD cost for display with enough precision to show
// at least one significant digit. Very small amounts get more decimal places.
func formatCost(cost float64) string {
	switch {
	case cost >= 0.01:
		return fmt.Sprintf("$%.2f", cost)
	case cost >= 0.001:
		return fmt.Sprintf("$%.4f", cost)
	case cost >= 0.0001:
		return fmt.Sprintf("$%.5f", cost)
	default:
		return fmt.Sprintf("$%.6f", cost)
	}
}

func formatCostResult(result types.CostResult) string {
	switch result.Status {
	case types.CostStatusFree:
		return "free"
	case types.CostStatusUnknown:
		return "cost unknown"
	case types.CostStatusPartial:
		return "partial " + formatCost(result.Total)
	default:
		return formatCost(result.Total)
	}
}

// formatTokenCount formats a token count for compact display.
// Examples: 1234 → "1,234", 150000 → "150k", 1500000 → "1.5m".
func formatTokenCount(tokens int) string {
	switch {
	case tokens >= 1_000_000:
		v := float64(tokens) / 1_000_000
		if v == float64(int(v)) {
			return fmt.Sprintf("%dm", int(v))
		}
		return fmt.Sprintf("%.1fm", v)
	case tokens >= 10_000:
		return fmt.Sprintf("%dk", tokens/1000)
	default:
		return fmt.Sprintf("%d", tokens)
	}
}

// formatBytes formats a byte count for compact display.
// Examples: 500 → "500B", 15360 → "15KB", 1572864 → "1.5MB".
func formatBytes(bytes int) string {
	switch {
	case bytes >= 1_000_000:
		return fmt.Sprintf("%.1fMB", float64(bytes)/1_000_000)
	case bytes >= 1_000:
		return fmt.Sprintf("%dKB", bytes/1000)
	default:
		return fmt.Sprintf("%dB", bytes)
	}
}
