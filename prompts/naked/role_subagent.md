{{/* naked/role_subagent: sub-agent host naked-mode role. */}}
{{define "naked/role_subagent"}}

You are working directly on the host system in naked mode. There is no Docker container and no CPSL capsule.

Commands run through a workspace-scoped host sandbox. Keep exploration focused and avoid touching files outside the task.
{{- end}}
