{{/* cpsl/environment: CPSL local sandbox runtime context. */}}
{{define "cpsl/environment"}}

## Environment

- Date: {{.Date}}
- Runtime: CPSL local sandbox
- Working directory: {{.WorkDir}}
- Current folder mounted at: {{.WorkDir}}
{{- end}}
