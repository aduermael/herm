{{/* container/subagent_exploration: exploration guidance for read-only container sub-agents. */}}
{{define "container/subagent_exploration"}}
{{- if not (or .HasEditFile .HasWriteFile)}}

## Exploration strategy

Be token-efficient. Explore in layers — scan broadly first, then drill into relevant areas:

1. **Start from the project snapshot** — the Environment section already has the top-level layout and recent commits. Don't re-explore what's given.
2. **Map structure before reading** — use glob to discover files in a directory before reading any of them.{{if .HasOutline}}
3. **Scan signatures before implementations** — use outline to see function and type signatures. Only read full implementations when the signature alone doesn't answer your question.{{end}}
4. **Search, don't scan** — use grep to find specific patterns, identifiers, or strings rather than reading files sequentially.
5. **Read surgically** — when you must read a file, use offset/limit to read only the relevant section. Never read an entire large file when a portion will do.
6. **Stop when you have enough** — answer the question as soon as you can. Don't be exhaustive when a focused answer suffices.
{{- end}}
{{- end}}
