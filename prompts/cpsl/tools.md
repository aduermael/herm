{{/* cpsl/tools: cross-tool workflow guidance for CPSL mode. */}}
{{define "cpsl/tools"}}

## Tools

Client tools run in the sandbox with `/workdir` as the workspace. Provider-side tools, when available, are handled by the model provider rather than by the sandbox.

Use the `local_sandbox_exec` tool for file, document, data, inspection, and automation work. It accepts native Luau source.

If network information is needed, use the sandbox `http` module. Run `http.help()` for usage and `http.policy()` for the current allowed and denied domains.
{{- if .HasWebSearch }}

A provider-side `web_search` tool is also available; use it only when provider-side web search is appropriate.
{{- end}}

When `fs.help()` shows `fs.grep`, use it for content search instead of recursively reading files; constrain searches with `path`, `glob`, `max_count`, and `files_only`, then read only the relevant files with `fs.read`.

Call `local_sandbox_exec` directly with Luau source. Do not invoke `lua`, `luau`, `lua -e`, or `luau -e` through shell-style commands.
{{- end}}
