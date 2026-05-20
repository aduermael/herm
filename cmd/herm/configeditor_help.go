// configeditor_help.go renders compact keyboard-hint rows for the config
// editor using reusable inline blocks.
package main

func (a *App) configHelpRows() []string {
	width := a.width
	if width <= 0 {
		width = 80
	}
	if a.cfgEditing {
		return layoutDimInlineBlocks(width, "Enter=confirm", "Esc=cancel")
	}
	parts := []string{"←/→=tab"}
	fields := a.cfgCurrentFields()
	if len(fields) > 0 {
		parts = append(parts, "↑/↓=select")
		enterHint := "Enter=edit"
		if a.cfgTab == cfgTabRouting {
			enterHint = "Enter=select"
		} else if field, ok := a.configSelectedField(); ok && (field.action != nil || field.picker != nil || field.toggle != nil) {
			enterHint = "Enter=select"
		}
		parts = append(parts, enterHint)
	}
	if a.cfgTab == cfgTabProject && a.projectConfigRoot() != "" {
		if field, ok := a.configSelectedField(); ok && field.set != nil && field.get != nil && field.get(a.cfgDraft) != "" {
			parts = append(parts, "Backspace=unset")
		}
	}
	parts = append(parts, "Esc=close")

	blocks := make([]inlineBlock, 0, len(parts)+1)
	for _, part := range parts {
		blocks = append(blocks, dimInlineBlock(part))
	}
	if a.hasUnsavedConfigDrafts() {
		blocks = append(blocks, styledInlineBlock(styledInlineBlockOptions{
			style: runningStatusStyle(a.configAnimationElapsed()),
			text:  "Ctrl+S=save",
		}))
	}
	return layoutInlineBlocks(layoutInlineBlocksOptions{blocks: blocks, width: width})
}
