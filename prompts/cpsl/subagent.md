{{/* cpsl/subagent: sub-agent prompt assembly for CPSL mode. */}}
{{define "cpsl/subagent"}}
{{template "cpsl/environment" .}}
{{template "common/project_context" .}}
{{template "common/subagent_intro" .}}
{{template "cpsl/role_subagent" .}}
{{template "cpsl/subagent_exploration" .}}
{{template "common/subagent_budget" .}}
{{template "cpsl/tools" .}}
{{template "cpsl/practices" .}}
{{- end}}
