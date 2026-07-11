package main

import (
	"testing"
	"unsafe"
)

func TestStringFromCStopsAtNUL(t *testing.T) {
	value := []byte("cpsl\x00ignored")
	if got := stringFromC(unsafe.Pointer(&value[0])); got != "cpsl" {
		t.Fatalf("stringFromC() = %q, want %q", got, "cpsl")
	}
}
