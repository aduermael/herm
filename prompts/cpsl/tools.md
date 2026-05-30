{{/* cpsl/tools: cross-tool workflow guidance for CPSL mode. */}}
{{define "cpsl/tools"}}

## Tools

Client tools run inside the CPSL local sandbox at `/workdir`. Provider-side tools, when available, are handled by the model provider rather than by CPSL.

Prefer the `luau` tool for CPSL-supported file, document, data, and automation work. Luau is CPSL's native runtime, and sandbox modules are available directly as globals. For capability discovery, run `help()`; for exact module usage, run `<module>.help()`.

Use the `bash` tool as a compatibility interface for simple shell-style commands. Bash input is transpiled into CPSL Luau, not executed by a host shell. In Bash-compatible mode, run `help` and `<module> help`. If a command is unavailable, adapt within CPSL and preserve the CPSL-only execution rule.
{{- end}}
