package main

import (
	"bytes"
	"testing"
)

func TestTerminalTitleSequences(t *testing.T) {
	var buf bytes.Buffer

	saveTerminalTitle(&buf)
	setHermTerminalTitle(&buf)
	restoreTerminalTitle(&buf)

	want := "\033]22;0\a\033]0;\U0001F41A herm\a\033]23;0\a"
	if got := buf.String(); got != want {
		t.Fatalf("terminal title sequence = %q, want %q", got, want)
	}
}
