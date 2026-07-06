// cpsl_library.go validates CPSL native metadata and builds session
// configuration JSON for Herm's mounted sandbox workspace.
package main

import (
	"encoding/json"
	"fmt"
	"slices"
	"sort"
	"unsafe"
)

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
	if !slices.Contains(metadata.Languages, cpslLanguageLuau) {
		return fmt.Errorf("CPSL metadata does not advertise native Luau support")
	}
	if !slices.Contains(metadata.Languages, cpslLanguageBash) {
		return fmt.Errorf("CPSL metadata does not advertise bash compatibility support")
	}
	if !metadata.Capabilities.Mounts || !metadata.Capabilities.NetworkPolicy {
		return fmt.Errorf("CPSL metadata does not advertise required capabilities")
	}
	return nil
}

func stringFromC(value unsafe.Pointer) string {
	if value == nil {
		return ""
	}
	var bytes []byte
	for offset := uintptr(0); ; offset++ {
		b := *(*byte)(unsafe.Add(value, offset))
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

type cpslSessionConfigJSONOptions struct {
	workspace    string
	skillsPath   string
	mounts       []validatedCPSLMount
	allowDomains []string
	denyDomains  []string
}

func cpslSessionConfigJSON(opts cpslSessionConfigJSONOptions) (string, error) {
	configMounts := []cpslMountConfig{{
		Host:        opts.workspace,
		VirtualPath: cpslWorkerInitialCW,
		Mode:        cpslMountModeReadWrite,
	}}
	if opts.skillsPath != "" {
		configMounts = append(configMounts, cpslMountConfig{
			Host:        opts.skillsPath,
			VirtualPath: skillsVirtualRoot,
			Mode:        cpslMountModeReadOnly,
		})
	}
	sortedMounts := append([]validatedCPSLMount(nil), opts.mounts...)
	sort.Slice(sortedMounts, func(i, j int) bool {
		return sortedMounts[i].VirtualPath < sortedMounts[j].VirtualPath
	})
	for _, mount := range sortedMounts {
		configMounts = append(configMounts, cpslMountConfig{
			Host:        mount.HostPath,
			VirtualPath: mount.VirtualPath,
			Mode:        mount.Mode,
		})
	}
	allowDomains := opts.allowDomains
	denyDomains := opts.denyDomains
	if len(sortedMounts) > 0 {
		allowDomains = nil
		denyDomains = nil
	}
	config := cpslSessionConfig{
		Mounts:     configMounts,
		InitialCWD: cpslWorkerInitialCW,
		Language:   cpslLanguageLuau,
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
