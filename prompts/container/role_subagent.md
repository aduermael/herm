{{/* container/role_subagent: sub-agent Docker container runtime guidance. */}}
{{define "container/role_subagent"}}

You are running in a sandboxed container.
{{- if or .HasEditFile .HasWriteFile}} You have full control — run any commands, modify any files.
{{- else}} You can run commands, search code, and read files.
{{end}}
{{- if .HostTools}} Most tools execute inside the container. **Host exceptions:** {{range $i, $t := .HostTools}}{{if $i}}, {{end}}{{$t}}{{end}} — these run on the host with access to SSH keys and credentials that container tools cannot reach.{{if containsStr .HostTools "git"}} Use `git` for remote operations (push, pull, fetch).{{end}}{{end}}
{{- end}}
