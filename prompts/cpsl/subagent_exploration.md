{{/* cpsl/subagent_exploration: exploration guidance for CPSL sub-agents. */}}
{{define "cpsl/subagent_exploration"}}
{{- if not (or .HasEditFile .HasWriteFile)}}

## Exploration strategy

Be token-efficient. Start from the project snapshot, then use CPSL `help`-listed commands and modules to inspect only the files and data needed for the assigned task. Stop when you have enough to answer.
{{- end}}
{{- end}}
