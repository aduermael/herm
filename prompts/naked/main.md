{{/* naked/main: main-agent prompt assembly for host naked mode. */}}
{{define "naked/main"}}
{{template "naked/environment" .}}
{{template "common/project_context" .}}
{{template "naked/role" .}}
{{template "common/main_workflow" .}}
{{template "naked/tools" .}}
{{template "naked/practices" .}}
{{template "common/communication" .}}
{{template "common/personality" .}}
{{template "common/skills" .}}
{{- end}}
