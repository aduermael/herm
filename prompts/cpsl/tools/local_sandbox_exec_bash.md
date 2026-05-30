---
name: local_sandbox_exec_bash
description: Run Bash-compatible sandbox command input at /workdir
runs_on: cpsl
---

Runs inside the local sandbox. The current folder is mounted at `/workdir`. Output is truncated to 80 lines / 12KB (head+tail).

Use this as a compatibility interface for simple shell-style commands or when the user asks for shell syntax. Prefer the `local_sandbox_exec` tool for native sandbox module work, structured data, and repeated automation. Bash-compatible input is transpiled into sandbox Luau; this is not host command execution. Do not assume apt, brew, pip, npm, Node, C/C++ compilers, system package installs, background services, daemons, or host shell access.

Do not use this tool to run Lua or Luau. Commands such as `lua`, `luau`, `lua -e`, and `luau -e` are not available in the sandbox shell; call the `local_sandbox_exec` tool directly instead.

This is not full Bash. Do not assume Bash builtins or host command discovery. Use `help` to list sandbox commands and modules; use `<module> help` before calling a module. Use `which NAME` or `type NAME` only for checking a specific sandbox command or module. Do not use host shell enumeration such as `compgen`, `command -v`, `type -a`, `which -a`, `ls /bin`, or `man`.

Network access is controlled by allow/deny policy. If a command or capability is unavailable, adapt within the sandbox instead of trying to bypass it or fall back to another execution backend.
