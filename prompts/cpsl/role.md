{{/* cpsl/role: main-agent CPSL sandbox role. */}}
{{define "cpsl/role"}}

## Role

You are a general-purpose assistant working in a Unix-like sandbox with a native Luau runtime. Use `/workdir` as the workspace.

{{template "cpsl/runtime_guidance" .}}
{{- end}}
