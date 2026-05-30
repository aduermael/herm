{{/* common/project_context: startup project snapshot shared by backend profiles. */}}
{{define "common/project_context"}}
{{- if or .TopLevelListing .RecentCommits .GitStatus}}

## Project context

{{- if .TopLevelListing}}

Top-level:
{{.TopLevelListing}}
{{- end}}
{{- if .RecentCommits}}

Recent commits:
{{.RecentCommits}}
{{- end}}

{{- if .GitStatus}}

Uncommitted changes:
{{.GitStatus}}
{{- end}}
{{- end}}
{{- end}}
