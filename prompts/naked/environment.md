{{/* naked/environment: host naked-mode runtime context. */}}
{{define "naked/environment"}}

## Environment

- Date: {{.Date}}
- Runtime: host system, naked mode
- Workspace: {{.WorkDir}}
- Command approval store: {{.WorkDir}}/.herm/approved_commands.json
{{- end}}
