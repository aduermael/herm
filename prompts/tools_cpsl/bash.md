---
name: bash
description: Run a shell command in CPSL at /workdir
runs_on: cpsl
---

Runs inside CPSL, a lightweight sandboxed Unix-like runtime. The current folder is mounted at `/workdir`. Output is truncated to 80 lines / 12KB (head+tail).

Use bash for CPSL-supported file, document, data, and lightweight automation tasks. Do not assume apt, brew, pip, npm, Node, C/C++ compilers, system package installs, background services, daemons, Docker, or host shell access.

Network access is controlled by CPSL allow/deny policy. If a command or capability is unavailable, adapt within CPSL instead of trying to bypass the sandbox.
