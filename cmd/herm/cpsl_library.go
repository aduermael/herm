package main

import (
	"encoding/json"
	"fmt"
	"unsafe"
)

type cpslSession uintptr

type cpslBackendMetadata struct {
	Name         string   `json:"name"`
	ABIVersion   uint32   `json:"abi_version"`
	Version      string   `json:"version"`
	Languages    []string `json:"languages"`
	Capabilities struct {
		Mounts        bool `json:"mounts"`
		NetworkPolicy bool `json:"network_policy"`
	} `json:"capabilities"`
}

func loadCPSLNativeLibrary(path string) (*cpslNativeLibrary, error) {
	lib, err := openCPSLNativeLibrary(path)
	if err != nil {
		return nil, err
	}
	ok := false
	defer func() {
		if !ok {
			_ = lib.close()
		}
	}()

	if err := validateCPSLNativeLibrary(lib); err != nil {
		return nil, err
	}
	ok = true
	return lib, nil
}

func validateCPSLNativeLibrary(lib *cpslNativeLibrary) error {
	abiVersion, err := lib.abiVersion()
	if err != nil {
		return err
	}
	if abiVersion != cpslABIVersion {
		return fmt.Errorf("unsupported CPSL ABI version %d", abiVersion)
	}

	metadataJSON, err := lib.backendMetadataJSON()
	if err != nil {
		return err
	}
	return validateCPSLBackendMetadataJSON(metadataJSON)
}

func validateCPSLBackendMetadataJSON(metadataJSON string) error {
	var metadata cpslBackendMetadata
	if err := json.Unmarshal([]byte(metadataJSON), &metadata); err != nil {
		return fmt.Errorf("invalid CPSL metadata: %w", err)
	}
	if metadata.Name != "cpsl" {
		return fmt.Errorf("invalid CPSL metadata name %q", metadata.Name)
	}
	if metadata.ABIVersion != cpslABIVersion {
		return fmt.Errorf("invalid CPSL metadata ABI version %d", metadata.ABIVersion)
	}
	if !containsString(metadata.Languages, cpslWorkerLanguage) {
		return fmt.Errorf("CPSL metadata does not advertise bash support")
	}
	if !metadata.Capabilities.Mounts || !metadata.Capabilities.NetworkPolicy {
		return fmt.Errorf("CPSL metadata does not advertise required capabilities")
	}
	return nil
}

func containsString(values []string, target string) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
}

func stringFromC(value unsafe.Pointer) string {
	if value == nil {
		return ""
	}
	var bytes []byte
	for ptr := uintptr(value); ; ptr++ {
		b := *(*byte)(unsafe.Pointer(ptr))
		if b == 0 {
			return string(bytes)
		}
		bytes = append(bytes, b)
	}
}

type cpslSessionConfig struct {
	Mounts     []cpslMountConfig `json:"mounts"`
	InitialCWD string            `json:"initial_cwd"`
	Language   string            `json:"language"`
	HTTP       cpslHTTPConfig    `json:"http"`
}

type cpslMountConfig struct {
	Host        string `json:"host"`
	VirtualPath string `json:"virtual"`
	Mode        string `json:"mode"`
}

type cpslHTTPConfig struct {
	Mode         string   `json:"mode"`
	AllowDomains []string `json:"allow_domains"`
	DenyDomains  []string `json:"deny_domains"`
}

func cpslSessionConfigJSON(workspace string, allowDomains, denyDomains []string) (string, error) {
	config := cpslSessionConfig{
		Mounts: []cpslMountConfig{{
			Host:        workspace,
			VirtualPath: cpslWorkerInitialCW,
			Mode:        "rw",
		}},
		InitialCWD: cpslWorkerInitialCW,
		Language:   cpslWorkerLanguage,
		HTTP: cpslHTTPConfig{
			Mode:         "policy",
			AllowDomains: cloneCPSLStringList(allowDomains),
			DenyDomains:  cloneCPSLStringList(denyDomains),
		},
	}
	data, err := json.Marshal(config)
	if err != nil {
		return "", err
	}
	return string(data), nil
}

func cloneCPSLStringList(values []string) []string {
	if values == nil {
		return []string{}
	}
	return append([]string(nil), values...)
}
