---
name: bash
description: Run a host shell command in the workspace sandbox
runs_on: host
---

Runs on the host system through the workspace-scoped sandbox. Output is truncated to 80 lines / 12KB (head+tail).

New command segments, outside-workspace file paths, and host network access require user approval. An approval requirement is not a refusal. Treat "can you use/read/access this outside path" as a task request, not as a question about capability. If the user asks you to use, read, inspect, list, run in, or access an outside-workspace path, call this tool with the narrow command and path needed instead of answering that approval is required; Herm will prompt for approval automatically. Do not refuse solely because a requested path is outside the workspace. Prefer `sandbox_permissions: "with_additional_permissions"` with `additional_permissions.file_system.read`, `.write`, or `network.enabled` when one command needs explicit sandboxed access. If an important command fails because of sandboxing or a likely sandbox-related network error, retry with the narrow additional permissions needed. Use `sandbox_permissions: "require_escalated"` only when a command must run outside the workspace sandbox after approval. You may include `prefix_rule` only for a narrow reusable argv prefix, such as `["npm", "run", "dev"]`; avoid broad prefixes like `["python"]` or destructive commands. Always-accepted permissions are recorded in `.herm/permissions.json` after approval. Users may add regex permissions to that file; do not add regex permissions yourself. Keep commands narrow and readable so approval prompts are clear.

The sandbox allows workspace writes. Outside-workspace access is approval-gated and remains blocked if approval is denied. Do not rely on Docker, CPSL modules, or container-only paths.
