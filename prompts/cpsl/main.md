{{/* cpsl/main: main-agent prompt assembly for CPSL mode. */}}
{{define "cpsl/main"}}
{{template "cpsl/environment" .}}
{{template "common/project_context" .}}
{{template "cpsl/role" .}}
{{template "common/main_workflow" .}}
{{template "cpsl/tools" .}}
{{template "cpsl/practices" .}}
{{template "common/communication" .}}
{{template "common/personality" .}}
{{template "common/skills" .}}
{{- end}}
