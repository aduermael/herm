package main

import (
	"bytes"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestParseCLI_CPSLFlags(t *testing.T) {
	libPath := writeTestCPSLLibrary(t)
	var stderr bytes.Buffer

	opts, err := parseCLI(parseCLIOptions{
		args: []string{
			"--cpsl", libPath,
			"--allow-domain", "example.com",
			"--allow-domain", "api.example.com",
			"--deny-domain", "blocked.example.com",
			"--deny-domain", "blocked-api.example.com",
			"-p", "say ok",
		},
		stderr: &stderr,
	})
	if err != nil {
		t.Fatalf("parseCLI: %v", err)
	}
	if stderr.String() != "" {
		t.Fatalf("stderr = %q, want empty", stderr.String())
	}
	wantPath, err := filepath.EvalSymlinks(libPath)
	if err != nil {
		t.Fatal(err)
	}
	if opts.cpsl.LibraryPath != wantPath {
		t.Fatalf("LibraryPath = %q, want %q", opts.cpsl.LibraryPath, wantPath)
	}
	if !reflect.DeepEqual(opts.cpsl.AllowDomains, []string{"example.com", "api.example.com"}) {
		t.Fatalf("AllowDomains = %#v", opts.cpsl.AllowDomains)
	}
	if !reflect.DeepEqual(opts.cpsl.DenyDomains, []string{"blocked.example.com", "blocked-api.example.com"}) {
		t.Fatalf("DenyDomains = %#v", opts.cpsl.DenyDomains)
	}
	if opts.prompt != "say ok" {
		t.Fatalf("prompt = %q, want %q", opts.prompt, "say ok")
	}
}

func TestParseCLI_NakedFlag(t *testing.T) {
	var stderr bytes.Buffer
	opts, err := parseCLI(parseCLIOptions{args: []string{"--naked", "-p", "say ok"}, stderr: &stderr})
	if err != nil {
		t.Fatalf("parseCLI: %v", err)
	}
	if stderr.String() != "" {
		t.Fatalf("stderr = %q, want empty", stderr.String())
	}
	if !opts.naked {
		t.Fatal("naked flag was not set")
	}
	if opts.cpsl.LibraryPath != "" {
		t.Fatalf("CPSL library = %q, want empty", opts.cpsl.LibraryPath)
	}
	if opts.prompt != "say ok" {
		t.Fatalf("prompt = %q, want say ok", opts.prompt)
	}
}

func TestParseCLI_NakedAndCPSLMutuallyExclusive(t *testing.T) {
	libPath := writeTestCPSLLibrary(t)
	tests := [][]string{
		{"--naked", "--cpsl", libPath},
		{"--naked=true", "--cpsl", libPath},
	}
	for _, args := range tests {
		t.Run(strings.Join(args[:1], " "), func(t *testing.T) {
			var stderr bytes.Buffer
			_, err := parseCLI(parseCLIOptions{args: args, stderr: &stderr})
			if err == nil {
				t.Fatal("parseCLI returned nil error")
			}
			if !strings.Contains(stderr.String(), "mutually exclusive") {
				t.Fatalf("stderr = %q, want mutually exclusive error", stderr.String())
			}
		})
	}
}

func TestParseCLI_CPSLInvalidLibraryExactMessage(t *testing.T) {
	dirWithExt := filepath.Join(t.TempDir(), "libcpsl"+cpslLibraryExtension())
	if err := os.Mkdir(dirWithExt, 0o755); err != nil {
		t.Fatal(err)
	}
	wrongExt := filepath.Join(t.TempDir(), "libcpsl.txt")
	if err := os.WriteFile(wrongExt, []byte("not a library"), 0o644); err != nil {
		t.Fatal(err)
	}
	missing := filepath.Join(t.TempDir(), "missing"+cpslLibraryExtension())

	tests := []struct {
		name string
		args []string
	}{
		{name: "missing value", args: []string{"--cpsl"}},
		{name: "empty equals", args: []string{"--cpsl="}},
		{name: "empty next arg", args: []string{"--cpsl", ""}},
		{name: "nonexistent", args: []string{"--cpsl", missing}},
		{name: "directory", args: []string{"--cpsl", dirWithExt}},
		{name: "wrong extension", args: []string{"--cpsl", wrongExt}},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var stderr bytes.Buffer
			_, err := parseCLI(parseCLIOptions{args: tt.args, stderr: &stderr})
			if err == nil {
				t.Fatal("parseCLI returned nil error")
			}
			if stderr.String() != cpslLibraryErrorMessage+"\n" {
				t.Fatalf("stderr = %q, want exact CPSL library message", stderr.String())
			}
		})
	}
}

func TestParseCLI_CPSLRelativeLibraryPath(t *testing.T) {
	dir := t.TempDir()
	libName := "libcpsl" + cpslLibraryExtension()
	libPath := filepath.Join(dir, libName)
	if err := os.WriteFile(libPath, []byte("test library placeholder"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Chdir(dir)

	var stderr bytes.Buffer
	opts, err := parseCLI(parseCLIOptions{args: []string{"--cpsl", libName}, stderr: &stderr})
	if err != nil {
		t.Fatalf("parseCLI: %v", err)
	}
	if stderr.String() != "" {
		t.Fatalf("stderr = %q, want empty", stderr.String())
	}
	wantPath, err := filepath.EvalSymlinks(libPath)
	if err != nil {
		t.Fatal(err)
	}
	if opts.cpsl.LibraryPath != wantPath {
		t.Fatalf("LibraryPath = %q, want %q", opts.cpsl.LibraryPath, wantPath)
	}
}

func TestParseCLI_UnquotedPromptBehaviorUnchanged(t *testing.T) {
	var stderr bytes.Buffer
	opts, err := parseCLI(parseCLIOptions{args: []string{"-p", "say", "ok"}, stderr: &stderr})
	if err != nil {
		t.Fatalf("parseCLI: %v", err)
	}
	if opts.prompt != "say ok" {
		t.Fatalf("prompt = %q, want %q", opts.prompt, "say ok")
	}
	if stderr.String() != "" {
		t.Fatalf("stderr = %q, want empty", stderr.String())
	}
}

func TestParseCLI_FlagLikePromptArgumentStillErrors(t *testing.T) {
	var stderr bytes.Buffer
	_, err := parseCLI(parseCLIOptions{args: []string{"-p", "say", "ok", "--debug"}, stderr: &stderr})
	if err == nil {
		t.Fatal("parseCLI returned nil error")
	}
	if !strings.Contains(stderr.String(), "flag-like argument") {
		t.Fatalf("stderr = %q, want flag-like argument error", stderr.String())
	}
}

func writeTestCPSLLibrary(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "libcpsl"+cpslLibraryExtension())
	if err := os.WriteFile(path, []byte("test library placeholder"), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}
