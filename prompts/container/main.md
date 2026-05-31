{{/* container/main: main-agent prompt assembly for Docker/container mode. */}}
{{define "container/main"}}
{{template "container/environment" .}}
{{template "common/project_context" .}}
{{template "container/role" .}}
{{template "common/main_workflow" .}}
{{template "container/tools" .}}
{{template "container/practices" .}}
{{template "common/communication" .}}
{{template "common/personality" .}}
{{template "common/skills" .}}
{{- end}}
