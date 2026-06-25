// models_format.go contains model sorting and terminal display formatting helpers.
package main

import (
	"fmt"
	"sort"
	"strings"

	"langdag.com/langdag/types"
)

// sortModelsByColOptions is the parameter bundle for sortModelsByCol.
type sortModelsByColOptions struct {
	models []ModelDef
	col    int
	asc    bool
}

// sortModelsByCol sorts models in place by the given column.
// col: 0=Model(ID), 1=Provider, 2=Price(prompt), 3=ContextWindow.
func sortModelsByCol(opts sortModelsByColOptions) {
	models, col, asc := opts.models, opts.col, opts.asc
	sort.SliceStable(models, func(i, j int) bool {
		var less bool
		switch col {
		case 0:
			less = strings.ToLower(models[i].ID) < strings.ToLower(models[j].ID)
		case 1:
			less = strings.ToLower(modelDisplayProvider(models[i])) < strings.ToLower(modelDisplayProvider(models[j]))
		case 2:
			less = models[i].PromptPrice < models[j].PromptPrice
		case 3:
			less = models[i].ContextWindow < models[j].ContextWindow
		default:
			less = strings.ToLower(models[i].ID) < strings.ToLower(models[j].ID)
		}
		if !asc {
			return !less
		}
		return less
	})
}

// sortColNames maps column indices to config-friendly names.
var sortColNames = [4]string{"name", "provider", "price", "context"}

// sortColFromName returns the column index for a name, defaulting to 0.
func sortColFromName(name string) int {
	for i, n := range sortColNames {
		if n == name {
			return i
		}
	}
	return 0
}

// sortAscFromMap converts a config map (column name → ascending) to a [4]bool array.
// Missing columns default to ascending (true).
func sortAscFromMap(m map[string]bool) [4]bool {
	var result [4]bool
	for i, name := range sortColNames {
		if asc, ok := m[name]; ok {
			result[i] = asc
		} else {
			result[i] = true
		}
	}
	return result
}

// sortAscToMap converts a [4]bool array to a config map (column name → ascending).
func sortAscToMap(arr [4]bool) map[string]bool {
	m := make(map[string]bool, 4)
	for i, name := range sortColNames {
		m[name] = arr[i]
	}
	return m
}

// formatPrice formats a per-million-token price as "$X.XX".
func formatPrice(price float64) string {
	return fmt.Sprintf("$%.2f", price)
}

// formatPriceCompact formats a price dropping unnecessary trailing zeros.
// 5.0 → "$5", 0.15 → "$0.15", 0.80 → "$0.80", 15.0 → "$15".
func formatPriceCompact(price float64) string {
	if price == float64(int(price)) {
		return fmt.Sprintf("$%d", int(price))
	}
	return fmt.Sprintf("$%.2f", price)
}

// formatPricePerMOptions is the parameter bundle for formatPricePerM.
type formatPricePerMOptions struct {
	promptPrice     float64
	completionPrice float64
}

// formatPricePerM formats input/output prices per million tokens as "$X/$Y/M".
func formatPricePerM(opts formatPricePerMOptions) string {
	return formatPriceCompact(opts.promptPrice) + "/" + formatPriceCompact(opts.completionPrice) + "/M"
}

// formatPriceRangePerMOptions is the parameter bundle for formatPriceRangePerM.
type formatPriceRangePerMOptions struct {
	inputMin  float64
	inputMax  float64
	outputMin float64
	outputMax float64
}

func formatPriceRangePerM(opts formatPriceRangePerMOptions) string {
	return formatPriceCompact(opts.inputMin) + "-" + formatPriceCompact(opts.inputMax) + "/" + formatPriceCompact(opts.outputMin) + "-" + formatPriceCompact(opts.outputMax) + "/M"
}

func formatModelPrice(m ModelDef) string {
	if m.PriceLabel != "" {
		return m.PriceLabel
	}
	switch m.PricingStatus {
	case types.CostStatusFree:
		return "free"
	case types.CostStatusUnknown:
		return "unknown"
	case types.CostStatusPartial:
		return "partial"
	default:
		return formatPricePerM(formatPricePerMOptions{promptPrice: m.PromptPrice, completionPrice: m.CompletionPrice})
	}
}

func modelDisplayProvider(m ModelDef) string {
	if m.OwnerProvider != "" {
		return m.OwnerProvider
	}
	return m.Provider
}

func bareModelID(id string) string {
	_, model, ok := strings.Cut(id, "/")
	if !ok || model == "" {
		return id
	}
	return model
}

func modelMenuDisplayName(m ModelDef) string {
	if m.Label != "" {
		if strings.HasPrefix(m.Label, m.ID) {
			return bareModelID(m.ID) + strings.TrimPrefix(m.Label, m.ID)
		}
		return m.Label
	}
	return bareModelID(m.ID)
}

// formatContextWindow formats a token count for display.
// Examples: 128000 → "128k", 200000 → "200k", 1048576 → "1.0m".
func formatContextWindow(tokens int) string {
	if tokens >= 1000000 {
		v := float64(tokens) / 1000000.0
		if v == float64(int(v)) {
			return fmt.Sprintf("%dm", int(v))
		}
		return fmt.Sprintf("%.1fm", v)
	}
	return fmt.Sprintf("%dk", tokens/1000)
}

// formatModelMenuLinesOptions is the parameter bundle for formatModelMenuLines.
type formatModelMenuLinesOptions struct {
	models   []ModelDef
	activeID string
	sortCol  int
	sortAsc  bool
}

// formatModelMenuLines formats models as aligned multi-column menu lines.
// Columns: Model (ID), Provider, Price (prompt), Context Window.
// Returns a header string and the data lines.
// The active model is marked with ● at the end.
// sortCol (0-3) determines which column header is highlighted.
func formatModelMenuLines(opts formatModelMenuLinesOptions) (string, []string) {
	models, activeID, sortCol, sortAsc := opts.models, opts.activeID, opts.sortCol, opts.sortAsc
	// Column headers
	headers := [4]string{"Model", "Provider", "Price", "Context"}

	// Compute column widths (at least as wide as headers)
	maxName := visibleWidth(headers[0])
	maxProv := visibleWidth(headers[1])
	maxPrice := visibleWidth(headers[2])
	maxCtx := visibleWidth(headers[3])

	type entry struct {
		name, prov, price, ctx string
		active                 bool
	}
	entries := make([]entry, len(models))
	for i, m := range models {
		displayName := modelMenuDisplayName(m)
		e := entry{
			name:   displayName,
			prov:   modelDisplayProvider(m),
			price:  formatModelPrice(m),
			ctx:    formatContextWindow(m.ContextWindow),
			active: modelMatchesID(modelMatchesIDOptions{model: m, id: activeID}),
		}
		if visibleWidth(e.name) > maxName {
			maxName = visibleWidth(e.name)
		}
		if len(e.prov) > maxProv {
			maxProv = len(e.prov)
		}
		if len(e.price) > maxPrice {
			maxPrice = len(e.price)
		}
		if len(e.ctx) > maxCtx {
			maxCtx = len(e.ctx)
		}
		entries[i] = e
	}

	// Build header with sort indicator on active column
	// ▼ = list reads downward (A→Z / low→high), ▲ = list reads upward (Z→A / high→low)
	arrow := "▼"
	if !sortAsc {
		arrow = "▲"
	}
	hdrParts := make([]string, 4)
	widths := [4]int{maxName, maxProv, maxPrice, maxCtx}
	rightAlign := [4]bool{false, false, true, true}
	for j, h := range headers {
		label := h
		if j == sortCol {
			label = h + arrow
		}
		pad := widths[j] - visibleWidth(label)
		if pad < 0 {
			pad = 0
		}
		if rightAlign[j] {
			hdrParts[j] = strings.Repeat(" ", pad) + label
		} else {
			hdrParts[j] = label + strings.Repeat(" ", pad)
		}
	}
	header := hdrParts[0] + "  " + hdrParts[1] + "  " + hdrParts[2] + "  " + hdrParts[3]

	lines := make([]string, len(entries))
	for i, e := range entries {
		marker := " "
		if e.active {
			marker = "●"
		}
		// Pad name manually to account for invisible ANSI escape bytes.
		namePad := maxName - visibleWidth(e.name)
		if namePad < 0 {
			namePad = 0
		}
		// ● is 3 bytes but 1 visible char; adjust ctx width so right-align stays correct.
		ctxWidth := maxCtx
		if e.active {
			ctxWidth -= 2 // compensate for 2 extra bytes in ●
		}
		lines[i] = fmt.Sprintf("%s%s  %-*s  %*s  %*s %s",
			e.name,
			strings.Repeat(" ", namePad),
			maxProv, e.prov,
			maxPrice, e.price,
			ctxWidth, e.ctx,
			marker)
	}
	return header, lines
}
