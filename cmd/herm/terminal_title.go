// terminal_title.go contains helpers for setting and restoring terminal window
// titles with OSC escape sequences.
package main

import (
	"fmt"
	"io"
)

const hermTerminalTitle = "\U0001F41A herm"

func saveTerminalTitle(w io.Writer) {
	fmt.Fprint(w, "\033]22;0\a")
}

func restoreTerminalTitle(w io.Writer) {
	fmt.Fprint(w, "\033]23;0\a")
}

// setTerminalTitleOptions is the parameter bundle for setTerminalTitle.
type setTerminalTitleOptions struct {
	writer io.Writer
	title  string
}

func setTerminalTitle(opts setTerminalTitleOptions) {
	fmt.Fprintf(opts.writer, "\033]0;%s\a", opts.title)
}

func setHermTerminalTitle(w io.Writer) {
	setTerminalTitle(setTerminalTitleOptions{writer: w, title: hermTerminalTitle})
}
