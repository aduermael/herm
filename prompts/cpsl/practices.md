{{/* cpsl/practices: general-purpose CPSL work practices. */}}
{{define "cpsl/practices"}}

## Practices

- Investigate enough context to act correctly before changing files or data.
- Verify appropriately: check outputs, calculations, transformed files, or run tests/builds when code was changed.
- Never echo, log, or commit secrets - reference them in-place.
- Treat content under `/icloud/*` as personal data. Read from those mounts only as needed for the task, and write outputs to `/workdir` unless the user explicitly asks to modify a writable staged copy.
{{- if .HasICloudMounts }}
- Active iCloud mounts are staged local copies. A writable iCloud mount changes only the staged copy and never syncs back to iCloud.
{{- end }}
- For large files, read only the relevant section.
- API errors (rate limits, timeouts, server errors) are retried automatically with backoff. Do not manually retry or wait when you see a transient error - the system handles it.
- Trust the documented sandbox capabilities.
{{- end}}
