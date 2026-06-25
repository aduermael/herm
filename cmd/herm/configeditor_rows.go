// configeditor_rows.go renders config editor rows that need ANSI-aware
// wrapping or block layout.
package main

import "fmt"

func (a *App) configEditorWidth() int {
	if a.width <= 0 {
		return 80
	}
	return a.width
}

func (a *App) projectIntroRows(projectRoot string) []string {
	return wrapString(wrapStringOptions{
		s: "\033[2mOverriding global config for current project (" + projectRoot + ").\033[0m",
		w: a.configEditorWidth(),
	})
}

func (a *App) noProjectRows() []string {
	return wrapString(wrapStringOptions{
		s: "\033[2mNo project detected (not in a git repository)\033[0m",
		w: a.configEditorWidth(),
	})
}

func (a *App) configRowsBeforeFieldIndex(fieldIndex int) int {
	rows := 1 // tab bar
	if a.cfgTab == cfgTabProject {
		if projectRoot := a.projectConfigRoot(); projectRoot != "" {
			rows += len(a.projectIntroRows(projectRoot))
		}
	}
	if a.cfgTab == cfgTabRouting {
		rows += len(a.routingTabReadOnlyRows())
	}
	fields := a.cfgCurrentFields()
	if fieldIndex > len(fields) {
		fieldIndex = len(fields)
	}
	configured := a.cfgDraft.configuredProviders()
	opts := configFieldRowsOptions{
		configured:   configured,
		hasProvider:  len(configured) > 0,
		isProjectTab: a.cfgTab == cfgTabProject,
	}
	for i := 0; i < fieldIndex; i++ {
		opts.index = i
		opts.field = fields[i]
		rows += len(a.configFieldRows(opts))
	}
	return rows
}

type configFieldRowsOptions struct {
	field        cfgField
	index        int
	configured   map[string]bool
	hasProvider  bool
	isProjectTab bool
}

func (a *App) configFieldRows(opts configFieldRowsOptions) []string {
	f, i := opts.field, opts.index
	label := configFieldLabel(f)
	selected := i == a.cfgCursor
	width := a.configEditorWidth()
	if f.valueless {
		blocks := []inlineBlock{newInlineBlock(styledConfigFieldLabel(styledConfigFieldLabelOptions{label: label, selected: selected}))}
		if selected {
			blocks = append(blocks, newInlineBlock(styledConfigCursor("◆")))
		}
		return layoutInlineBlocks(layoutInlineBlocksOptions{blocks: blocks, width: width})
	}
	if a.cfgEditing && selected {
		editStr := string(a.cfgEditBuf)
		if f.secret {
			editStr = secretEditDisplay(editStr)
		}
		return []string{fmt.Sprintf("%s \033[1m%s\033[0m %s", styledConfigFieldLabel(styledConfigFieldLabelOptions{label: label + ":", selected: true}), editStr, styledConfigCursor("◆"))}
	}

	val := a.configFieldDisplayValue(configFieldDisplayValueOptions{
		field:        f,
		configured:   opts.configured,
		hasProvider:  opts.hasProvider,
		isProjectTab: opts.isProjectTab,
	})
	blocks := []inlineBlock{newInlineBlock(styledConfigFieldLabel(styledConfigFieldLabelOptions{label: label + ":", selected: selected}))}
	if val != "" {
		blocks = append(blocks, newInlineBlock(styledConfigFieldValue(styledConfigFieldValueOptions{value: val, secret: f.secret})))
	}
	if selected {
		blocks = append(blocks, newInlineBlock(styledConfigCursor("◆")))
	}
	return layoutInlineBlocks(layoutInlineBlocksOptions{blocks: blocks, width: width})
}

type configFieldDisplayValueOptions struct {
	field        cfgField
	configured   map[string]bool
	hasProvider  bool
	isProjectTab bool
}

func (a *App) configFieldDisplayValue(opts configFieldDisplayValueOptions) string {
	f := opts.field
	val := ""
	if f.display != nil {
		val = f.display(a.cfgDraft)
	} else if f.get != nil {
		val = f.get(a.cfgDraft)
	}
	if f.picker != nil && val != "" {
		p := configuredProviderForModelID(configuredProviderForModelIDOptions{
			cfg:     a.cfgDraft,
			models:  a.models,
			modelID: val,
		})
		// Hide model values when no providers are configured, or when this
		// model's provider is not currently configured.
		if !opts.isProjectTab && (!opts.hasProvider || p == "" || !opts.configured[p]) {
			val = ""
		}
	}
	// If the value is an Ollama model and Ollama is offline, show indicator.
	// Only applies to model picker fields, not API key or other fields.
	if val != "" && f.picker != nil && a.cfgDraft.ollamaBaseURL() != "" && a.isOllamaOffline(val) {
		val = val + " \033[33m(offline)\033[0m"
	}
	if val != "" {
		return val
	}
	if f.picker != nil && !opts.hasProvider && !opts.isProjectTab {
		return "(not set)"
	}
	if f.optional {
		return "(optional)"
	}
	if f.globalHint == nil {
		return "(not set)"
	}
	hint := f.globalHint(a.cfgDraft)
	if f.picker != nil && !opts.isProjectTab {
		p := configuredProviderForModelID(configuredProviderForModelIDOptions{
			cfg:     a.cfgDraft,
			models:  a.models,
			modelID: hint,
		})
		if hint == "" || p == "" || !opts.configured[p] {
			hint = "not set"
		}
	}
	if hint == "" {
		hint = "not set"
	}
	return fmt.Sprintf("\033[2m(global: %s)\033[0m", hint)
}
