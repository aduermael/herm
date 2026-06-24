// render_approval.go renders approval prompts and command previews.
package main

import "strings"

type renderApprovalCodeRowsOptions struct {
	text  string
	width int
}

func renderApprovalCodeRows(opts renderApprovalCodeRowsOptions) []string {
	width := opts.width
	if width <= 0 {
		width = 80
	}
	lines := strings.Split(strings.ReplaceAll(opts.text, "\r", ""), "\n")
	var rows []string
	for _, line := range lines {
		if line == "" {
			line = " "
		}
		wrapped := wrapString(wrapStringOptions{s: approvalDetailStyle + line, w: width})
		for i := range wrapped {
			row := wrapped[i]
			if pad := (width - visibleWidth(row)) / 2; pad > 0 {
				row = approvalDetailStyle + strings.Repeat(" ", pad) + row
			}
			rows = append(rows, fillStyledRow(fillStyledRowOptions{row: row, fillStyle: inputBgStyle}))
		}
	}
	return rows
}

type renderApprovalOptionsRowOptions struct {
	selected int
	width    int
}

func renderApprovalOptionsRow(opts renderApprovalOptionsRowOptions) string {
	labels := []string{"Accept once [y]", "Always accept [cmd+y]", "Deny [n]"}
	parts := make([]string, 0, len(labels))
	for i, label := range labels {
		if i == opts.selected {
			parts = append(parts, "\033[7m "+label+" \033[27m")
		} else {
			parts = append(parts, " "+label+" ")
		}
	}
	row := strings.Join(parts, "  ")
	if visibleWidth(row) > opts.width && opts.width > 0 {
		row = strings.Join([]string{"[y] once", "[cmd+y] always", "[n] deny"}, "  ")
	}
	if opts.width > 0 && visibleWidth(row) < opts.width {
		row = strings.Repeat(" ", (opts.width-visibleWidth(row))/2) + row
	}
	return approvalTextRow(row)
}
