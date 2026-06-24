---
name: request_permissions
description: Request sandboxed host permissions before running a command
runs_on: host
---

Requests user approval for sandboxed file or network access before running a host command.

Use this when you need permission before you can construct the exact `bash` command. Request only `network` and `file_system` permissions. Prefer narrow paths and avoid broad directory access.

If the user asks whether you can use, inspect, or access an outside-workspace path and the exact command is not yet clear, call this tool instead of answering that approval is required.

Approved permissions are applied to subsequent naked-mode sandboxed `bash` commands. Use `bash` with `sandbox_permissions: "require_escalated"` only when sandboxed permissions cannot satisfy the task.
