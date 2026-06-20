{{/* common/skills: project-specific skill content loaded from .herm/skills/. */}}
{{define "common/skills"}}{{if .Skills}}

## Skills

{{range .Skills}}- **{{.Name}}**: {{.Description}}
{{end}}{{range .Skills}}
### {{.Name}}

{{.Content}}
{{end}}{{end}}{{end}}
