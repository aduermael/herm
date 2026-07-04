{{/* common/skills: lazily loaded skill metadata from .agents/skills and ~/.agents/skills. */}}
{{define "common/skills"}}{{if .Skills}}

## Skills

The following skills are available. Their full instructions are not loaded into this prompt. When a skill is relevant to the user's task, read its skill file first, then follow that file's instructions and read any referenced support files from the same folder as needed.

{{range .Skills}}- **{{.Name}}**: {{.Description}} Read: `{{.Path}}`
{{end}}{{end}}{{end}}
