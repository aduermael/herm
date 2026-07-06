package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestValidateCPSLMountDescriptorsAcceptsSortedStagedMounts(t *testing.T) {
	workspace := t.TempDir()
	stageA := t.TempDir()
	stageB := t.TempDir()

	mounts, err := validateCPSLMountDescriptors(workspace, []cpslMountDescriptor{
		testICloudMountDescriptor(stageB, "/icloud/zeta"),
		testICloudMountDescriptor(stageA, "/icloud/project"),
	})
	if err != nil {
		t.Fatalf("validateCPSLMountDescriptors: %v", err)
	}
	if len(mounts) != 2 {
		t.Fatalf("mount count = %d, want 2", len(mounts))
	}
	if mounts[0].VirtualPath != "/icloud/project" || mounts[1].VirtualPath != "/icloud/zeta" {
		t.Fatalf("mounts not sorted by virtual path: %#v", mounts)
	}
	if mounts[0].Mode != cpslMountModeReadOnly {
		t.Fatalf("default mode = %q, want ro", mounts[0].Mode)
	}
}

func TestValidateCPSLMountDescriptorsRejectsUnsafeDescriptors(t *testing.T) {
	workspace := t.TempDir()
	stage := t.TempDir()
	filePath := filepath.Join(t.TempDir(), "file")
	if err := os.WriteFile(filePath, []byte("not a dir"), 0o644); err != nil {
		t.Fatal(err)
	}

	tests := []struct {
		name      string
		mounts    []cpslMountDescriptor
		wantError string
	}{
		{
			name:      "bad virtual root",
			mounts:    []cpslMountDescriptor{withVirtual(testICloudMountDescriptor(stage, "/files/project"), "/files/project")},
			wantError: "under /icloud/<slug>",
		},
		{
			name:      "bad slug",
			mounts:    []cpslMountDescriptor{withVirtual(testICloudMountDescriptor(stage, "/icloud/Project"), "/icloud/Project")},
			wantError: "invalid character",
		},
		{
			name:      "nested virtual path",
			mounts:    []cpslMountDescriptor{withVirtual(testICloudMountDescriptor(stage, "/icloud/project/nested"), "/icloud/project/nested")},
			wantError: "exactly /icloud/<slug>",
		},
		{
			name:      "unsupported provider",
			mounts:    []cpslMountDescriptor{withSourceKind(testICloudMountDescriptor(stage, "/icloud/project"), "file-provider-directory")},
			wantError: "source_kind",
		},
		{
			name:      "unsupported platform",
			mounts:    []cpslMountDescriptor{withPlatform(testICloudMountDescriptor(stage, "/icloud/project"), "watchos")},
			wantError: "source_platform",
		},
		{
			name:      "rw without staged flag",
			mounts:    []cpslMountDescriptor{withMode(testICloudMountDescriptor(stage, "/icloud/project"), cpslMountModeReadWrite, false)},
			wantError: "writable_staged_copy=true",
		},
		{
			name:      "host inside workdir",
			mounts:    []cpslMountDescriptor{testICloudMountDescriptor(workspace, "/icloud/project")},
			wantError: "outside /workdir",
		},
		{
			name:      "host is not a directory",
			mounts:    []cpslMountDescriptor{testICloudMountDescriptor(filePath, "/icloud/project")},
			wantError: "existing directory",
		},
		{
			name: "duplicate virtual path",
			mounts: []cpslMountDescriptor{
				testICloudMountDescriptor(t.TempDir(), "/icloud/project"),
				testICloudMountDescriptor(t.TempDir(), "/icloud/project"),
			},
			wantError: "duplicate virtual",
		},
		{
			name: "overlapping host paths",
			mounts: func() []cpslMountDescriptor {
				parent := t.TempDir()
				child := filepath.Join(parent, "child")
				if err := os.Mkdir(child, 0o755); err != nil {
					t.Fatal(err)
				}
				return []cpslMountDescriptor{
					withMode(testICloudMountDescriptor(parent, "/icloud/a"), cpslMountModeReadWrite, true),
					testICloudMountDescriptor(child, "/icloud/b"),
				}
			}(),
			wantError: "overlaps",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := validateCPSLMountDescriptors(workspace, tt.mounts)
			if err == nil || !strings.Contains(err.Error(), tt.wantError) {
				t.Fatalf("error = %v, want containing %q", err, tt.wantError)
			}
		})
	}
}

func TestCPSLPromptMountsFromDescriptorsSanitizesLabels(t *testing.T) {
	mounts, err := cpslPromptMountsFromDescriptors([]cpslMountDescriptor{
		withLabel(testICloudMountDescriptor("/host/path/not/read", "/icloud/project"), "Project\nName\t\"Q3\""),
	})
	if err != nil {
		t.Fatalf("cpslPromptMountsFromDescriptors: %v", err)
	}
	if len(mounts) != 1 {
		t.Fatalf("mount count = %d, want 1", len(mounts))
	}
	if mounts[0].Label != `Project Name "Q3"` {
		t.Fatalf("label = %q", mounts[0].Label)
	}
	if strings.Contains(formatCPSLMountTable(mounts), "/host/path") {
		t.Fatalf("mount table leaked host path: %s", formatCPSLMountTable(mounts))
	}
}

func testICloudMountDescriptor(hostPath, virtualPath string) cpslMountDescriptor {
	return cpslMountDescriptor{
		Label:          "Project",
		HostPath:       hostPath,
		VirtualPath:    virtualPath,
		SourcePlatform: "ipados",
		SourceKind:     cpslICloudSourceKind,
		AccessLifetime: cpslAccessLifetime,
		HydrationState: cpslHydrationState,
	}
}

func withVirtual(descriptor cpslMountDescriptor, virtualPath string) cpslMountDescriptor {
	descriptor.VirtualPath = virtualPath
	return descriptor
}

func withSourceKind(descriptor cpslMountDescriptor, sourceKind string) cpslMountDescriptor {
	descriptor.SourceKind = sourceKind
	return descriptor
}

func withPlatform(descriptor cpslMountDescriptor, platform string) cpslMountDescriptor {
	descriptor.SourcePlatform = platform
	return descriptor
}

func withMode(descriptor cpslMountDescriptor, mode string, writableStagedCopy bool) cpslMountDescriptor {
	descriptor.Mode = mode
	descriptor.WritableStagedCopy = writableStagedCopy
	return descriptor
}

func withLabel(descriptor cpslMountDescriptor, label string) cpslMountDescriptor {
	descriptor.Label = label
	return descriptor
}
