package main

type backendPromptProfile struct {
	mainSections        []string
	subAgentSections    []string
	toolDescriptionDirs []string
	includeContainerEnv bool
	workflowFirstStep   string
	projectOrientation  string
	workDir             func(string) string
}

func promptProfileForBackend(backend backendKind) backendPromptProfile {
	switch backend {
	case backendCPSL:
		return backendPromptProfile{
			mainSections: []string{
				"cpsl/environment",
				"common/project_context",
				"cpsl/role",
				"common/main_workflow",
				"cpsl/tools",
				"common/practices",
				"common/communication",
				"common/personality",
				"common/skills",
			},
			subAgentSections: []string{
				"cpsl/environment",
				"common/project_context",
				"common/subagent_intro",
				"cpsl/role_subagent",
				"cpsl/subagent_exploration",
				"common/subagent_budget",
				"cpsl/tools",
				"common/practices",
			},
			toolDescriptionDirs: []string{"cpsl/tools"},
			workflowFirstStep:   "Understand what's needed — inspect relevant files and data with native Luau and sandbox modules, ask if ambiguous. If a command or runtime is missing, adapt within the sandbox.",
			projectOrientation:  "The Environment section contains a pre-gathered project snapshot. Use it to orient yourself before inspecting files through the sandbox. If you need deeper context, inspect only the key files needed for the task.",
			workDir:             func(string) string { return cpslWorkerInitialCW },
		}
	default:
		return backendPromptProfile{
			mainSections: []string{
				"container/environment",
				"common/project_context",
				"container/role",
				"common/main_workflow",
				"container/tools",
				"common/practices",
				"common/communication",
				"common/personality",
				"common/skills",
			},
			subAgentSections: []string{
				"container/environment",
				"common/project_context",
				"common/subagent_intro",
				"container/role_subagent",
				"container/subagent_exploration",
				"common/subagent_budget",
				"container/tools",
				"common/practices",
			},
			toolDescriptionDirs: []string{"container/tools"},
			includeContainerEnv: true,
			workflowFirstStep:   "Understand what's needed — read relevant code, ask if ambiguous. If tools/runtimes are missing, use devenv to build a proper image first.",
			projectOrientation:  "The Environment section contains a pre-gathered project snapshot — top-level structure, recent commits, and uncommitted changes. Use this to orient yourself instead of running `ls`, `git log`, or `git status`. If you need deeper context, check key config files (go.mod, package.json, Dockerfile, Makefile), find entry points, or scan the README.",
			workDir:             func(hostWorkDir string) string { return hostWorkDir },
		}
	}
}
