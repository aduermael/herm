{{/* cpsl/tools: cross-tool workflow guidance for CPSL mode. */}}
{{define "cpsl/tools"}}

## Tools

Client tools run inside the CPSL local sandbox at `/workdir`. Provider-side tools, when available, are handled by the model provider rather than by CPSL.

Use bash for CPSL-supported file, document, data, and automation work. This is Bash-compatible input into the sandbox, not host command execution. If a command is unavailable, adapt within CPSL and preserve the CPSL-only execution rule.
{{- end}}
