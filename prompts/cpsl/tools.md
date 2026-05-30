{{/* cpsl/tools: cross-tool workflow guidance for CPSL mode. */}}
{{define "cpsl/tools"}}

## Tools

Client tools run inside the local sandbox at `/workdir`. Provider-side tools, when available, are handled by the model provider rather than by the sandbox.

Use the `luau` tool by default for file, document, data, inspection, and automation work. Luau is the sandbox's native runtime, and sandbox modules are available directly as globals. For capability discovery, run `help()`; for exact module usage, run `<module>.help()`.

Do not run `lua`, `luau`, `lua -e`, or `luau -e` through a shell command. The `luau` agent tool is the native Luau entry point.

{{- if .HasBash}}
Use the `bash` tool as a compatibility interface for simple shell-style commands. Bash input is transpiled into sandbox Luau, not executed by a host shell. In Bash-compatible mode, run `help` and `<module> help`. If a command is unavailable, adapt within the sandbox and preserve the no-fallback rule.
{{- else}}
No shell/Bash execution tool is exposed to the agent in this mode. Use native Luau and sandbox modules for inspection, file work, and automation.
{{- end}}
{{- end}}
