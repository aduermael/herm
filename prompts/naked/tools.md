{{/* naked/tools: cross-tool workflow guidance for host naked mode. */}}
{{define "naked/tools"}}

## Tools

Client tools run on the host through the workspace-scoped sandbox. Use `bash` for file inspection, edits, tests, builds, and git operations.

New shell command segments and outside-workspace file paths require user approval. Always-accepted permissions are stored in `.herm/permissions.json` and can run again without another prompt. Users may edit that file to add `command_regexes` or `path_regexes`; do not add regex permissions yourself. Keep commands specific and minimal so approvals stay understandable.
{{- if .HasWebSearch }}

A provider-side `web_search` tool is also available; use it only when provider-side web search is appropriate.
{{- end}}

Prefer fast, focused shell tools: `rg --files` for discovery, `rg` for search, and language-native test commands for verification. Avoid long-running background services unless the task explicitly requires them.
{{- end}}
