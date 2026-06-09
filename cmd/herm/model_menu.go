// model_menu.go contains model picker sorting and scroll helpers.
package main

// refreshModelMenu re-sorts and re-formats the model menu after a sort change.
// Preserves the cursor on the same model.
func (a *App) refreshModelMenu() {
	if len(a.menuModels) == 0 {
		return
	}
	var cursorID string
	if a.menuCursor >= 0 && a.menuCursor < len(a.menuModels) {
		cursorID = a.menuModels[a.menuCursor].ID
	}
	asc := a.menuSortAsc[a.menuSortCol]
	sortModelsByCol(sortModelsByColOptions{models: a.menuModels, col: a.menuSortCol, asc: asc})
	header, lines := formatModelMenuLines(formatModelMenuLinesOptions{models: a.menuModels, activeID: a.menuActiveID, sortCol: a.menuSortCol, sortAsc: asc})
	a.menuHeader = header
	a.menuLines = lines
	for i, m := range a.menuModels {
		if m.ID == cursorID {
			a.menuCursor = i
			break
		}
	}
	maxVisible := getTerminalHeight() * 60 / 100
	if maxVisible < 1 {
		maxVisible = 1
	}
	if a.menuCursor < a.menuScrollOffset {
		a.menuScrollOffset = a.menuCursor
	} else if a.menuCursor >= a.menuScrollOffset+maxVisible {
		a.menuScrollOffset = a.menuCursor - maxVisible + 1
	}
	a.globalConfig.ModelSortCol = sortColNames[a.menuSortCol]
	a.globalConfig.ModelSortDirs = sortAscToMap(a.menuSortAsc)
	a.rebuildEffectiveConfig()
	_ = saveConfig(a.globalConfig)
}
