package main

import (
	"testing"

	"langdag.com/langdag/types"
)

func TestServerToolsForRuntimeContainerUsesModelCapability(t *testing.T) {
	models := []ModelDef{{ID: "model-with-search", ServerTools: []string{types.ServerToolWebSearch}}}

	got := serverToolsForRuntime(serverToolsForRuntimeOptions{
		backend: backendContainer,
		modelID: "model-with-search",
		models:  models,
	})

	if len(got) != 1 || got[0].Name != types.ServerToolWebSearch {
		t.Fatalf("server tools = %#v, want web_search", got)
	}
}

func TestServerToolsForRuntimeCPSLRequiresWildcardAllowDomain(t *testing.T) {
	models := []ModelDef{{ID: "model-with-search", ServerTools: []string{types.ServerToolWebSearch}}}

	restricted := serverToolsForRuntime(serverToolsForRuntimeOptions{
		backend: backendCPSL,
		cpsl:    cpslConfig{AllowDomains: []string{"example.com"}},
		modelID: "model-with-search",
		models:  models,
	})
	if len(restricted) != 0 {
		t.Fatalf("restricted CPSL server tools = %#v, want none", restricted)
	}

	unrestricted := serverToolsForRuntime(serverToolsForRuntimeOptions{
		backend: backendCPSL,
		cpsl:    cpslConfig{AllowDomains: []string{"*"}},
		modelID: "model-with-search",
		models:  models,
	})
	if len(unrestricted) != 1 || unrestricted[0].Name != types.ServerToolWebSearch {
		t.Fatalf("unrestricted CPSL server tools = %#v, want web_search", unrestricted)
	}
}

func TestServerToolsForRuntimeCPSLDenyDisablesWildcardAllowDomain(t *testing.T) {
	models := []ModelDef{{ID: "model-with-search", ServerTools: []string{types.ServerToolWebSearch}}}

	got := serverToolsForRuntime(serverToolsForRuntimeOptions{
		backend: backendCPSL,
		cpsl: cpslConfig{
			AllowDomains: []string{"*"},
			DenyDomains:  []string{"blocked.example.com"},
		},
		modelID: "model-with-search",
		models:  models,
	})

	if len(got) != 0 {
		t.Fatalf("CPSL wildcard with deny server tools = %#v, want none", got)
	}
}
