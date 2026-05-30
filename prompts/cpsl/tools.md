{{/* cpsl/tools: cross-tool workflow guidance for CPSL mode. */}}
{{define "cpsl/tools"}}

## Tools

Client tools run inside the CPSL local sandbox at `/workdir`. Provider-side tools, when available, are handled by the model provider rather than by CPSL.

The `bash` tool accepts Bash-compatible input into CPSL. It is not a host shell. For capability discovery, run `help`; for exact module usage, run `<module> help`. Prefer CPSL modules for structured file, document, data, and automation work. If a command is unavailable, adapt within CPSL and preserve the CPSL-only execution rule.
{{- end}}
