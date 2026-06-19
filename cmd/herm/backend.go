// backend.go selects and validates Herm execution backends, including CPSL
// library configuration and platform-specific library extensions.
package main

import (
	"errors"
	"os"
	"path/filepath"
	"runtime"
)

const cpslLibraryErrorMessage = "You need to provide a CPSL sandbox library."

var errCPSLLibrary = errors.New(cpslLibraryErrorMessage)

type backendKind int

const (
	backendContainer backendKind = iota
	backendCPSL
)

type cpslConfig struct {
	LibraryPath  string
	AllowDomains []string
	DenyDomains  []string
}

func validateCPSLLibraryPath(path string) (string, error) {
	if path == "" {
		return "", errCPSLLibrary
	}
	if !filepath.IsAbs(path) {
		abs, err := filepath.Abs(path)
		if err != nil {
			return "", errCPSLLibrary
		}
		path = abs
	}
	if filepath.Ext(path) != cpslLibraryExtension() {
		return "", errCPSLLibrary
	}
	info, err := os.Stat(path)
	if err != nil || !info.Mode().IsRegular() {
		return "", errCPSLLibrary
	}
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil {
		return "", errCPSLLibrary
	}
	return resolved, nil
}

func cpslLibraryExtension() string {
	switch runtime.GOOS {
	case "darwin":
		return ".dylib"
	case "windows":
		return ".dll"
	default:
		return ".so"
	}
}
