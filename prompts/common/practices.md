{{/* common/practices: backend-neutral work practices. */}}
{{define "common/practices"}}

## Practices

- Investigate enough context to act correctly before changing files or data.
- Verify appropriately for the task and summarize verification failures with the next useful step.
- Never echo, log, or commit secrets — reference them in-place.
- For large files, read only the relevant section.
- API errors (rate limits, timeouts, server errors) are retried automatically with backoff. Do not manually retry or wait when you see a transient error — the system handles it.
- Trust the documented environment capabilities.
{{- end}}
