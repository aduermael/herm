{{/* common/project_context: startup project snapshot shared by backend profiles. */}}
{{define "common/project_context"}}
{{- if or .TopLevelListing .IsGitRepo .GitStatus}}

## Project context

{{- if .TopLevelListing}}

{{.ProjectFilesLabel}}:
{{.TopLevelListing}}
{{- end}}
{{- if .IsGitRepo}}

{{.ProjectGitRepoLabel}}:
{{- if .RecentCommits}}
{{.RecentCommits}}
{{- else}}
(none)
{{- end}}
{{- end}}

{{- if .GitStatus}}

{{.ProjectGitStatusLabel}}:
{{.GitStatus}}
{{- end}}
{{- end}}
{{- end}}
