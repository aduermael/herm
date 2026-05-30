---
name: git
description: Run git commands on the host in the project worktree
runs_on: host
---

Runs on the host (not in the container). Run git commands in the project worktree. Only the host has SSH keys and credentials for remote operations.

Allowed subcommands: status, diff, log, show, branch, checkout, add, commit, pull, push, fetch, stash, rebase, merge, reset, tag.

Remote operations (push, pull, fetch) MUST go through this tool — they fail inside the container. Push requires user approval. Never force-push unless the user explicitly asks.
