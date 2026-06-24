---
name: bash
description: Run a host shell command in the workspace sandbox
runs_on: host
---

Runs on the host system through the workspace-scoped sandbox. Output is truncated to 80 lines / 12KB (head+tail).

New command segments require user approval and are recorded in `.herm/approved_commands.json` after approval. Keep commands narrow and readable so approval prompts are clear.

The sandbox allows workspace writes and blocks writes outside the workspace. Do not rely on Docker, CPSL modules, or container-only paths.
