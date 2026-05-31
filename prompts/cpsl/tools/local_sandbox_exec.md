---
name: local_sandbox_exec
description: Run native Luau source in the sandbox at /workdir
runs_on: cpsl
---

Runs native Luau in the Unix-like sandbox with `/workdir` as the workspace. Output is truncated to 80 lines / 12KB (head+tail).

Use this as the default execution tool for sandbox work. Do not assume any Luau module is available from prior knowledge; call `help()` to discover modules and `<module>.help()` before using one.

For requests phrased as Lua or Luau execution, call this tool directly with the script. For general sandbox execution, inspection, file/data work, and repetitive scripting, use this tool. Do not run `lua`, `luau`, `lua -e`, or `luau -e` through a shell command; those are not sandbox commands.

Prefer Luau and sandbox modules for structured file, document, data, and automation work. For repeated or multi-step automation, keep reusable `.luau` source under `/workdir/.herm/luau/` or an existing project scripts directory, then pass that source through this tool instead of regenerating it. Do not assume a shell command can execute a `.luau` file path.

This is not a host Lua interpreter with filesystem or process access. Do not use `io`, `os`, `loadfile`, `dofile`, host shell commands, package managers, background services, or files outside sandbox workspace paths.
