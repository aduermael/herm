// cpsl_mounts.go validates CPSL iCloud Drive session mount descriptors and
// formats sanitized mount metadata for prompts.
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	pathpkg "path"
	"path/filepath"
	"sort"
	"strings"
	"unicode"
)

const (
	cpslMountModeReadOnly  = "ro"
	cpslMountModeReadWrite = "rw"

	cpslICloudVirtualRoot  = "/icloud"
	cpslICloudSourceKind   = "icloud-drive-directory"
	cpslAccessLifetime     = "session"
	cpslHydrationState     = "staged"
	cpslSessionConfigLimit = 1 << 20
)

type cpslWorkerSessionConfigFile struct {
	Workspace string                `json:"workspace,omitempty"`
	Mounts    []cpslMountDescriptor `json:"mounts,omitempty"`
}

type cpslMountDescriptor struct {
	ScopeID            string `json:"scope_id,omitempty"`
	Label              string `json:"label"`
	HostPath           string `json:"host_path"`
	VirtualPath        string `json:"virtual_path"`
	Mode               string `json:"mode,omitempty"`
	SourcePlatform     string `json:"source_platform"`
	SourceKind         string `json:"source_kind"`
	AccessLifetime     string `json:"access_lifetime"`
	HydrationState     string `json:"hydration_state"`
	WritableStagedCopy bool   `json:"writable_staged_copy,omitempty"`
}

type validatedCPSLMount struct {
	HostPath    string
	VirtualPath string
	Mode        string
}

type cpslPromptMount struct {
	VirtualPath    string
	Mode           string
	Label          string
	SourcePlatform string
}

func loadCPSLWorkerSessionConfig(path string) (cpslWorkerSessionConfigFile, error) {
	file, err := os.Open(path)
	if err != nil {
		return cpslWorkerSessionConfigFile{}, err
	}
	defer file.Close()

	decoder := json.NewDecoder(io.LimitReader(file, cpslSessionConfigLimit))
	decoder.DisallowUnknownFields()
	var config cpslWorkerSessionConfigFile
	if err := decoder.Decode(&config); err != nil {
		return cpslWorkerSessionConfigFile{}, fmt.Errorf("invalid CPSL session config: %w", err)
	}
	if decoder.Decode(&struct{}{}) != io.EOF {
		return cpslWorkerSessionConfigFile{}, fmt.Errorf("invalid CPSL session config: multiple JSON values")
	}
	return config, nil
}

func validateCPSLSessionConfigPath(path string) (string, error) {
	if strings.TrimSpace(path) == "" {
		return "", fmt.Errorf("missing CPSL session config path")
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return "", err
	}
	info, err := os.Stat(abs)
	if err != nil {
		return "", err
	}
	if !info.Mode().IsRegular() {
		return "", fmt.Errorf("CPSL session config is not a regular file")
	}
	resolved, err := filepath.EvalSymlinks(abs)
	if err != nil {
		return "", err
	}
	return resolved, nil
}

func cpslPromptMountsFromSessionConfigFile(path string) ([]cpslPromptMount, error) {
	config, err := loadCPSLWorkerSessionConfig(path)
	if err != nil {
		return nil, err
	}
	return cpslPromptMountsFromDescriptors(config.Mounts)
}

func cpslPromptMountsFromDescriptors(descriptors []cpslMountDescriptor) ([]cpslPromptMount, error) {
	mounts := make([]cpslPromptMount, 0, len(descriptors))
	for i, descriptor := range descriptors {
		virtualPath, slug, err := validateICloudVirtualPath(descriptor.VirtualPath)
		if err != nil {
			return nil, fmt.Errorf("mount %d virtual_path: %w", i, err)
		}
		mode, err := normalizedCPSLMountMode(descriptor.Mode)
		if err != nil {
			return nil, fmt.Errorf("mount %s: %w", virtualPath, err)
		}
		if err := validateICloudDescriptorMetadata(descriptor); err != nil {
			return nil, fmt.Errorf("mount %s: %w", virtualPath, err)
		}
		label := sanitizedPromptField(descriptor.Label)
		if label == "" {
			label = slug
		}
		mounts = append(mounts, cpslPromptMount{
			VirtualPath:    virtualPath,
			Mode:           mode,
			Label:          label,
			SourcePlatform: displaySourcePlatform(descriptor.SourcePlatform),
		})
	}
	sort.Slice(mounts, func(i, j int) bool {
		return mounts[i].VirtualPath < mounts[j].VirtualPath
	})
	return mounts, nil
}

func validateCPSLMountDescriptors(workspace string, descriptors []cpslMountDescriptor) ([]validatedCPSLMount, error) {
	if len(descriptors) == 0 {
		return nil, nil
	}
	workspace = filepath.Clean(workspace)
	seenVirtual := map[string]bool{}
	seenHost := map[string]bool{}
	mounts := make([]validatedCPSLMount, 0, len(descriptors))

	for i, descriptor := range descriptors {
		virtualPath, _, err := validateICloudVirtualPath(descriptor.VirtualPath)
		if err != nil {
			return nil, fmt.Errorf("mount %d virtual_path: %w", i, err)
		}
		mode, err := normalizedCPSLMountMode(descriptor.Mode)
		if err != nil {
			return nil, fmt.Errorf("mount %s: %w", virtualPath, err)
		}
		if err := validateICloudDescriptorMetadata(descriptor); err != nil {
			return nil, fmt.Errorf("mount %s: %w", virtualPath, err)
		}
		if mode == cpslMountModeReadWrite && !descriptor.WritableStagedCopy {
			return nil, fmt.Errorf("mount %s: rw iCloud mounts require writable_staged_copy=true", virtualPath)
		}
		if seenVirtual[virtualPath] {
			return nil, fmt.Errorf("duplicate virtual mount path %s", virtualPath)
		}
		hostPath, err := canonicalMountHostPath(descriptor.HostPath)
		if err != nil {
			return nil, fmt.Errorf("mount %s host_path: %w", virtualPath, err)
		}
		if pathOverlaps(hostPath, workspace) {
			return nil, fmt.Errorf("mount %s host_path must be outside /workdir", virtualPath)
		}
		if seenHost[hostPath] {
			return nil, fmt.Errorf("duplicate host path for mount %s", virtualPath)
		}

		mounts = append(mounts, validatedCPSLMount{
			HostPath:    hostPath,
			VirtualPath: virtualPath,
			Mode:        mode,
		})
		seenVirtual[virtualPath] = true
		seenHost[hostPath] = true
	}

	sort.Slice(mounts, func(i, j int) bool {
		return mounts[i].VirtualPath < mounts[j].VirtualPath
	})

	for i := range mounts {
		for j := i + 1; j < len(mounts); j++ {
			if virtualPathsOverlap(mounts[i].VirtualPath, mounts[j].VirtualPath) {
				return nil, fmt.Errorf("mount %s shadows %s", mounts[i].VirtualPath, mounts[j].VirtualPath)
			}
			if pathOverlaps(mounts[i].HostPath, mounts[j].HostPath) {
				return nil, fmt.Errorf("mount %s host_path overlaps %s", mounts[i].VirtualPath, mounts[j].VirtualPath)
			}
		}
	}

	return mounts, nil
}

func normalizedCPSLMountMode(mode string) (string, error) {
	if mode == "" {
		return cpslMountModeReadOnly, nil
	}
	switch mode {
	case cpslMountModeReadOnly, cpslMountModeReadWrite:
		return mode, nil
	default:
		return "", fmt.Errorf("mode must be ro or rw")
	}
}

func validateICloudDescriptorMetadata(descriptor cpslMountDescriptor) error {
	if descriptor.SourceKind != cpslICloudSourceKind {
		return fmt.Errorf("source_kind must be %s", cpslICloudSourceKind)
	}
	if !isSupportedICloudSourcePlatform(descriptor.SourcePlatform) {
		return fmt.Errorf("source_platform must be macos, ios, or ipados")
	}
	if descriptor.AccessLifetime != cpslAccessLifetime {
		return fmt.Errorf("access_lifetime must be session")
	}
	if descriptor.HydrationState != cpslHydrationState {
		return fmt.Errorf("hydration_state must be staged")
	}
	return nil
}

func validateICloudVirtualPath(value string) (string, string, error) {
	if value == "" {
		return "", "", fmt.Errorf("must not be empty")
	}
	if !strings.HasPrefix(value, cpslICloudVirtualRoot+"/") {
		return "", "", fmt.Errorf("must be under %s/<slug>", cpslICloudVirtualRoot)
	}
	if pathpkg.Clean(value) != value {
		return "", "", fmt.Errorf("must be normalized")
	}
	parts := strings.Split(strings.TrimPrefix(value, "/"), "/")
	if len(parts) != 2 || parts[0] != strings.TrimPrefix(cpslICloudVirtualRoot, "/") {
		return "", "", fmt.Errorf("must be exactly %s/<slug>", cpslICloudVirtualRoot)
	}
	slug := parts[1]
	if err := validateCPSLMountSlug(slug); err != nil {
		return "", "", err
	}
	return value, slug, nil
}

func validateCPSLMountSlug(slug string) error {
	if slug == "" {
		return fmt.Errorf("slug must not be empty")
	}
	if len(slug) > 64 {
		return fmt.Errorf("slug is too long")
	}
	if slug == "." || slug == ".." {
		return fmt.Errorf("slug is reserved")
	}
	for i, r := range slug {
		valid := r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r == '-' || r == '_' || r == '.'
		if !valid {
			return fmt.Errorf("slug contains invalid character %q", r)
		}
		if (i == 0 || i == len(slug)-1) && !(r >= 'a' && r <= 'z' || r >= '0' && r <= '9') {
			return fmt.Errorf("slug must start and end with a lowercase letter or digit")
		}
	}
	return nil
}

func canonicalMountHostPath(hostPath string) (string, error) {
	if strings.TrimSpace(hostPath) == "" {
		return "", fmt.Errorf("must not be empty")
	}
	abs, err := filepath.Abs(hostPath)
	if err != nil {
		return "", err
	}
	resolved, err := filepath.EvalSymlinks(abs)
	if err != nil {
		return "", err
	}
	info, err := os.Stat(resolved)
	if err != nil {
		return "", err
	}
	if !info.IsDir() {
		return "", fmt.Errorf("must be an existing directory")
	}
	return filepath.Clean(resolved), nil
}

func isSupportedICloudSourcePlatform(platform string) bool {
	switch platform {
	case "macos", "ios", "ipados":
		return true
	default:
		return false
	}
}

func displaySourcePlatform(platform string) string {
	switch platform {
	case "macos":
		return "macOS"
	case "ios":
		return "iOS"
	case "ipados":
		return "iPadOS"
	default:
		return sanitizedPromptField(platform)
	}
}

func pathOverlaps(a, b string) bool {
	return pathContains(a, b) || pathContains(b, a)
}

func pathContains(parent, child string) bool {
	parent = filepath.Clean(parent)
	child = filepath.Clean(child)
	rel, err := filepath.Rel(parent, child)
	if err != nil {
		return false
	}
	return rel == "." || rel != ".." && !strings.HasPrefix(rel, ".."+string(os.PathSeparator))
}

func virtualPathsOverlap(a, b string) bool {
	return virtualPathContains(a, b) || virtualPathContains(b, a)
}

func virtualPathContains(parent, child string) bool {
	parent = pathpkg.Clean(parent)
	child = pathpkg.Clean(child)
	if parent == child {
		return true
	}
	if parent == "/" {
		return strings.HasPrefix(child, "/")
	}
	return strings.HasPrefix(child, parent+"/")
}

func sanitizedPromptField(value string) string {
	value = strings.TrimSpace(value)
	var b strings.Builder
	lastSpace := false
	for _, r := range value {
		if unicode.IsControl(r) {
			r = ' '
		}
		if unicode.IsSpace(r) {
			if lastSpace {
				continue
			}
			r = ' '
			lastSpace = true
		} else {
			lastSpace = false
		}
		b.WriteRune(r)
		if b.Len() >= 120 {
			break
		}
	}
	return strings.TrimSpace(b.String())
}

func hasCPSLICloudMounts(mounts []cpslPromptMount) bool {
	return len(mounts) > 0
}
