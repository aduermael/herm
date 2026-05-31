{{/* cpsl/role_subagent: sub-agent CPSL sandbox runtime guidance. */}}
{{define "cpsl/role_subagent"}}

You are working in a Unix-like sandbox with a native Luau runtime. Use `/workdir` as the workspace.

{{template "cpsl/runtime_guidance" .}}
{{- end}}
