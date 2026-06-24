{{/* naked/environment: host naked-mode runtime context. */}}
{{define "naked/environment"}}

## Environment

- Date: {{.Date}}
- Runtime: host system, naked mode
- Workspace: {{.WorkDir}}
- Permission store: {{.WorkDir}}/.herm/permissions.json
{{- end}}
