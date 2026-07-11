{{/* cpsl/environment: CPSL sandbox runtime context. */}}
{{define "cpsl/environment"}}

## Environment

- Date: {{.Date}}
- Runtime: Unix-like sandbox
- Workspace: {{.WorkDir}}
{{- end}}
