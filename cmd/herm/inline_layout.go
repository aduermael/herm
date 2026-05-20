// inline_layout.go provides reusable, ANSI-aware layout for compact terminal
// UI components that should wrap as whole blocks instead of word-wrapping.
package main

import "strings"

const ansiReset = "\033[0m"

type inlineBlock struct {
	text        string
	width       int
	forceOwnRow bool
}

func newInlineBlock(text string) inlineBlock {
	return normalizeInlineBlock(inlineBlock{text: text})
}

type styledInlineBlockOptions struct {
	style string
	text  string
}

func styledInlineBlock(opts styledInlineBlockOptions) inlineBlock {
	return newInlineBlock(opts.style + opts.text + ansiReset)
}

func dimInlineBlock(text string) inlineBlock {
	return styledInlineBlock(styledInlineBlockOptions{style: "\033[2m", text: text})
}

func normalizeInlineBlock(block inlineBlock) inlineBlock {
	if block.text == "" {
		return inlineBlock{}
	}
	text := ansiReset + block.text + ansiReset
	if strings.HasPrefix(block.text, ansiReset) {
		text = block.text
	}
	if !strings.HasSuffix(text, ansiReset) {
		text += ansiReset
	}
	return inlineBlock{text: text, width: visibleWidth(text), forceOwnRow: block.forceOwnRow}
}

func layoutDimInlineBlocks(width int, parts ...string) []string {
	blocks := make([]inlineBlock, 0, len(parts))
	for _, part := range parts {
		blocks = append(blocks, dimInlineBlock(part))
	}
	return layoutInlineBlocks(layoutInlineBlocksOptions{blocks: blocks, width: width})
}

type layoutInlineBlocksOptions struct {
	blocks         []inlineBlock
	width          int
	separator      string
	rightAlignLast bool
}

// layoutInlineBlocks lays out one-line UI blocks across rows. Blocks on the
// same row are separated automatically, never split across rows, and only
// ellipsized when a single block cannot fit on its own row.
func layoutInlineBlocks(opts layoutInlineBlocksOptions) []string {
	if opts.width <= 0 {
		return nil
	}

	separator := opts.separator
	if separator == "" {
		separator = " "
	}
	separatorWidth := visibleWidth(separator)

	blocks := make([]inlineBlock, 0, len(opts.blocks))
	for _, block := range opts.blocks {
		block = normalizeInlineBlock(block)
		if block.width == 0 {
			continue
		}
		if block.width > opts.width {
			text := truncateVisual(truncateVisualOptions{s: block.text, maxCols: opts.width})
			block = newInlineBlock(text)
			block.forceOwnRow = true
		}
		blocks = append(blocks, block)
	}
	if len(blocks) == 0 {
		return nil
	}

	if opts.rightAlignLast {
		totalWidth := 0
		for i, block := range blocks {
			if i > 0 {
				totalWidth += separatorWidth
			}
			totalWidth += block.width
		}
		if totalWidth <= opts.width {
			var row strings.Builder
			padding := opts.width - totalWidth
			for i, block := range blocks {
				switch {
				case i == 0 && len(blocks) == 1:
					row.WriteString(strings.Repeat(" ", padding))
				case i == len(blocks)-1:
					row.WriteString(strings.Repeat(" ", padding))
					row.WriteString(separator)
				case i > 0:
					row.WriteString(separator)
				}
				row.WriteString(block.text)
			}
			return []string{row.String()}
		}
	}

	var rows []string
	var cur strings.Builder
	curWidth := 0

	for _, block := range blocks {
		sepWidth := 0
		if curWidth > 0 {
			sepWidth = separatorWidth
		}
		if curWidth > 0 && (block.forceOwnRow || curWidth+sepWidth+block.width > opts.width) {
			rows = append(rows, cur.String())
			cur.Reset()
			curWidth = 0
			sepWidth = 0
		}
		if sepWidth > 0 {
			cur.WriteString(separator)
			curWidth += sepWidth
		}
		cur.WriteString(block.text)
		curWidth += block.width
	}

	if curWidth > 0 {
		rows = append(rows, cur.String())
	}
	return rows
}

type statusSegment = inlineBlock

func newStatusSegment(text string) statusSegment {
	return newInlineBlock(text)
}

func dimStatusSegment(text string) statusSegment {
	return dimInlineBlock(text)
}

type wrapStatusSegmentsOptions struct {
	segments       []statusSegment
	width          int
	separator      string
	rightAlignLast bool
}

func wrapStatusSegments(opts wrapStatusSegmentsOptions) []string {
	return layoutInlineBlocks(layoutInlineBlocksOptions{
		blocks:         opts.segments,
		width:          opts.width,
		separator:      opts.separator,
		rightAlignLast: opts.rightAlignLast,
	})
}
