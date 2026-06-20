{{/* cpsl/subagent_exploration: exploration guidance for CPSL sub-agents. */}}
{{define "cpsl/subagent_exploration"}}
{{- if not (or .HasEditFile .HasWriteFile)}}

## Exploration strategy

Be token-efficient. Start from the Project context snapshot, then use native Luau and sandbox modules to inspect only the files and data needed for the assigned task. Use `help()` and `<module>.help()` for discovery. Stop when you have enough to answer.
{{- end}}
{{- end}}
