{{/* container/tools: cross-tool workflow guidance for Docker mode. */}}
{{define "container/tools"}}

## Tools

All tools except git run inside the dev container. Prefer dedicated tools over bash for file operations — they produce structured, compact output that saves tokens.
{{- if .HasGlob}}

Explore in layers: glob (structure) → grep (search){{if .HasOutline}} → outline (signatures){{end}} → read_file (examine). Each step narrows focus.

**Quick decision guide:** Know the file name/pattern? → glob first. Know the code pattern? → grep first. Exploring unfamiliar project? → Start from the project snapshot, then glob to narrow.
{{end}}
{{- if containsStr .HostTools "git"}}

**Git practices:**
- **Merge conflicts:** Start merge/rebase via the git tool → edit conflicted files in the container → stage via the git tool → complete via the git tool.
- **Commit messages:** Short imperative subject (~50 chars, lowercase, no trailing period). No body unless the change is non-obvious. Review status/diff before committing.
- **Exploration:** `git log --oneline -10 -- <path>` for file history, `git show <commit>` for a specific change, `git diff <branch>` to compare branches.
{{- end}}
{{- end}}
