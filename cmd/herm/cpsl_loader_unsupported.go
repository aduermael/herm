//go:build !(darwin || linux || windows)

// cpsl_loader_unsupported.go provides the native-library stub for platforms
// where Herm cannot load CPSL dynamic libraries.
package main

import "fmt"

type cpslNativeLibrary struct{}

func openCPSLNativeLibrary(path string) (*cpslNativeLibrary, error) {
	return nil, fmt.Errorf("CPSL dynamic libraries are unsupported on this platform")
}

func (l *cpslNativeLibrary) abiVersion() (uint32, error) {
	return 0, fmt.Errorf("CPSL dynamic libraries are unsupported on this platform")
}

func (l *cpslNativeLibrary) backendMetadataJSON() (string, error) {
	return "", fmt.Errorf("CPSL dynamic libraries are unsupported on this platform")
}

func (l *cpslNativeLibrary) sessionNew(configJSON string) (cpslSession, error) {
	return 0, fmt.Errorf("CPSL dynamic libraries are unsupported on this platform")
}

func (l *cpslNativeLibrary) sessionFree(session cpslSession) {}

func (l *cpslNativeLibrary) eval(opts cpslSessionEvalOptions) (string, error) {
	return "", fmt.Errorf("CPSL dynamic libraries are unsupported on this platform")
}

func (l *cpslNativeLibrary) lastError() string {
	return ""
}

func (l *cpslNativeLibrary) close() error {
	return nil
}
