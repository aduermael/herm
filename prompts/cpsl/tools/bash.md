---
name: bash
description: Run Bash-compatible CPSL command input at /workdir
runs_on: cpsl
---

Runs inside the CPSL local sandbox. The current folder is mounted at `/workdir`. Output is truncated to 80 lines / 12KB (head+tail).

Use this as a compatibility interface for simple shell-style commands or when the user asks for shell syntax. Prefer the `luau` tool for native CPSL module work, structured data, and repeated automation. Bash-compatible input is transpiled into CPSL Luau; this is not host command execution. Do not assume apt, brew, pip, npm, Node, C/C++ compilers, system package installs, background services, daemons, or host shell access.

This is not full Bash. Do not assume Bash builtins or host command discovery. Use `help` to list CPSL commands and modules; use `<module> help` before calling a module. Use `which NAME` or `type NAME` only for checking a specific CPSL command or module. Do not use host shell enumeration such as `compgen`, `command -v`, `type -a`, `which -a`, `ls /bin`, or `man`.

Network access is controlled by CPSL allow/deny policy. If a command or capability is unavailable, adapt within CPSL instead of trying to bypass the sandbox or fall back to another execution backend.
