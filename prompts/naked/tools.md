{{/* naked/tools: cross-tool workflow guidance for host naked mode. */}}
{{define "naked/tools"}}

## Tools

Client tools run on the host through the workspace-scoped sandbox. Use `bash` for file inspection, edits, tests, builds, and git operations.

New shell command segments, outside-workspace file paths, and host network access require user approval. An approval requirement is not a refusal. Treat "can you use/read/access this outside path" as a task request, not as a question about capability. If the user asks you to use, read, inspect, list, run in, or access an outside-workspace path, make the tool call that requests access instead of answering that approval is required. Use `request_permissions` when you need access before deciding on the exact command; otherwise call `bash` with the narrow command and path needed so Herm prompts for approval automatically. Do not refuse solely because a requested path is outside the workspace. Prefer `sandbox_permissions: "with_additional_permissions"` with `additional_permissions.file_system.read`, `.write`, or `network.enabled` when one command needs explicit sandboxed access. If an important command fails because of sandboxing or a likely sandbox-related network error, retry with the narrow additional permissions needed. Use `sandbox_permissions: "require_escalated"` only when a command must run outside the workspace sandbox after approval. You may include `prefix_rule` only for a narrow reusable argv prefix, such as `["npm", "run", "dev"]`; avoid broad prefixes like `["python"]` or destructive commands. Always-accepted permissions are stored in `.herm/permissions.json` as exact commands, `command_prefixes`, and paths so they can run again without another prompt. Users may edit that file to add `command_regexes` or `path_regexes`; do not add regex permissions yourself. Keep commands specific and minimal so approvals stay understandable.
{{- if .HasRequestPermissions }}
Use `request_permissions` when you need to ask for sandboxed file or network access before deciding on the exact command. Request only `network` and `file_system` permissions.
{{- end}}
{{- if .HasWebSearch }}

A provider-side `web_search` tool is also available; use it only when provider-side web search is appropriate.
{{- end}}

Prefer fast, focused shell tools: `rg --files` for discovery, `rg` for search, and language-native test commands for verification. Avoid long-running background services unless the task explicitly requires them.
{{- end}}
