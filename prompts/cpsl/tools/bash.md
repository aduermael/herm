---
name: bash
description: Run a shell command in CPSL at /workdir
runs_on: cpsl
---

Runs inside the CPSL local sandbox. The current folder is mounted at `/workdir`. Output is truncated to 80 lines / 12KB (head+tail).

Use Bash-compatible input for CPSL-supported file, document, data, and lightweight automation tasks. This is not host command execution. Do not assume apt, brew, pip, npm, Node, C/C++ compilers, system package installs, background services, daemons, or host shell access.

Network access is controlled by CPSL allow/deny policy. If a command or capability is unavailable, adapt within CPSL instead of trying to bypass the sandbox or fall back to another execution backend.
