{{/* container/subagent: sub-agent prompt assembly for Docker/container mode. */}}
{{define "container/subagent"}}
{{template "container/environment" .}}
{{template "common/project_context" .}}
{{template "common/subagent_intro" .}}
{{template "container/role_subagent" .}}
{{template "container/subagent_exploration" .}}
{{template "common/subagent_budget" .}}
{{template "container/tools" .}}
{{template "container/practices" .}}
{{- end}}
