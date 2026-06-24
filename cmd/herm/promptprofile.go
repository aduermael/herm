// promptprofile.go selects system prompt templates and context labels for each
// execution backend supported by Herm.
package main

type backendPromptProfile struct {
	mainTemplate          string
	subAgentTemplate      string
	toolDescriptionDirs   []string
	includeContainerEnv   bool
	workflowFirstStep     string
	projectOrientation    string
	projectFilesLabel     string
	projectGitRepoLabel   string
	projectGitStatusLabel string
	workDir               func(string) string
}

func promptProfileForBackend(backend backendKind) backendPromptProfile {
	switch backend {
	case backendCPSL:
		return backendPromptProfile{
			mainTemplate:          "cpsl/main",
			subAgentTemplate:      "cpsl/subagent",
			toolDescriptionDirs:   []string{"cpsl/tools"},
			workflowFirstStep:     "Understand what's needed - inspect relevant files and data with native Luau and sandbox modules, ask if ambiguous. If a capability is missing, adapt within the sandbox.",
			projectOrientation:    "The Project context section contains a pre-gathered snapshot. Use it to orient yourself before inspecting files through the sandbox. If you need deeper context, inspect only the key files needed for the task.",
			projectFilesLabel:     "Files in /workdir (2 levels)",
			projectGitRepoLabel:   "/workdir is a git repository, recent commits",
			projectGitStatusLabel: "Uncommitted changes",
			workDir:               func(string) string { return cpslWorkerInitialCW },
		}
	case backendNaked:
		return backendPromptProfile{
			mainTemplate:          "naked/main",
			subAgentTemplate:      "naked/subagent",
			toolDescriptionDirs:   []string{"naked/tools"},
			workflowFirstStep:     "Understand what's needed - inspect relevant files and run focused host commands through the sandboxed bash tool, asking if ambiguous.",
			projectOrientation:    "The Project context section contains a pre-gathered snapshot. Use it to orient yourself before running host commands. If you need deeper context, inspect only the key files needed for the task.",
			projectFilesLabel:     "Files in workspace (2 levels)",
			projectGitRepoLabel:   "Workspace git repository, recent commits",
			projectGitStatusLabel: "Uncommitted changes",
			workDir:               func(hostWorkDir string) string { return hostWorkDir },
		}
	default:
		return backendPromptProfile{
			mainTemplate:          "container/main",
			subAgentTemplate:      "container/subagent",
			toolDescriptionDirs:   []string{"container/tools"},
			includeContainerEnv:   true,
			workflowFirstStep:     "Understand what's needed - read relevant code, ask if ambiguous. If tools/runtimes are missing, use devenv to build a proper image first.",
			projectOrientation:    "The Project context section contains a pre-gathered snapshot - top-level structure, recent commits, and uncommitted changes. Use this to orient yourself instead of running `ls`, `git log`, or `git status`. If you need deeper context, check key config files (go.mod, package.json, Dockerfile, Makefile), find entry points, or scan the README.",
			projectFilesLabel:     "Top-level",
			projectGitRepoLabel:   "Recent commits",
			projectGitStatusLabel: "Uncommitted changes",
			workDir:               func(hostWorkDir string) string { return hostWorkDir },
		}
	}
}
