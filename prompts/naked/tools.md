{{/* naked/tools: cross-tool workflow guidance for host naked mode. */}}
{{define "naked/tools"}}

## Tools

Client tools run on the host through the workspace-scoped sandbox. Use `bash` for file inspection, edits, tests, builds, and git operations.

New shell command segments require user approval. Approved command segments are stored in `.herm/approved_commands.json` and can run again without another prompt. Keep commands specific and minimal so approvals stay understandable.
{{- if .HasWebSearch }}

A provider-side `web_search` tool is also available; use it only when provider-side web search is appropriate.
{{- end}}

Prefer fast, focused shell tools: `rg --files` for discovery, `rg` for search, and language-native test commands for verification. Avoid long-running background services unless the task explicitly requires them.
{{- end}}
