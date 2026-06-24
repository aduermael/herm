{{/* naked/subagent: sub-agent prompt assembly for host naked mode. */}}
{{define "naked/subagent"}}
{{template "naked/environment" .}}
{{template "common/project_context" .}}
{{template "common/subagent_intro" .}}
{{template "naked/role_subagent" .}}
{{template "naked/subagent_exploration" .}}
{{template "common/subagent_budget" .}}
{{template "naked/tools" .}}
{{template "naked/practices" .}}
{{- end}}
