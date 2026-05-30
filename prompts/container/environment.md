{{/* container/environment: Docker container runtime context. */}}
{{define "container/environment"}}

## Environment

- Date: {{.Date}}
- Working directory: {{.WorkDir}}
- Container image: {{.ContainerImage}}
- Project mounted at: {{.WorkDir}}
{{- if .HostTools}}
- Host tools: {{range $i, $t := .HostTools}}{{if $i}}, {{end}}{{$t}}{{end}}{{if containsStr .HostTools "git"}} (worktree{{if .WorktreeBranch}}: {{.WorktreeBranch}}{{end}}){{end}}
{{- end}}
{{- if .HasBash}}
- Attachments mounted at: /attachments (files attached to the current message are available here)
{{- end}}
{{- if .ContainerEnv}}
{{.ContainerEnv}}
{{- end}}
{{- end}}
