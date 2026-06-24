{{/* naked/practices: general-purpose host naked-mode practices. */}}
{{define "naked/practices"}}

## Practices

- Investigate enough context to act correctly before changing files.
- Verify appropriately: run focused tests, builds, or command checks when code was changed.
- Never echo, log, or commit secrets - reference them in-place.
- For large files, read only the relevant section.
- API errors (rate limits, timeouts, server errors) are retried automatically with backoff. Do not manually retry or wait when you see a transient error - the system handles it.
- Remember that naked mode acts on the host workspace, not an isolated container filesystem.
{{- end}}
