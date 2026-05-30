---
name: local_sandbox_exec
description: Run native Luau source in the local sandbox at /workdir
runs_on: cpsl
---

Runs native Luau inside the local sandbox. The current folder is mounted at `/workdir`. Output is truncated to 80 lines / 12KB (head+tail).

Use this as the default execution tool for sandbox work. Sandbox modules are available as globals; call `help()` to list modules and `<module>.help()` before using a module, for example `fs.help()` or `json.help()`.

For requests phrased as Lua or Luau execution, call this tool directly with the script. For general sandbox execution, inspection, file/data work, and repetitive scripting, prefer this tool over compatibility interfaces. Do not run `lua`, `luau`, `lua -e`, or `luau -e` through a shell command; those are not sandbox commands.

Prefer Luau and sandbox modules for structured file, document, data, network-policy, and automation work. For repeated or multi-step automation, keep reusable `.luau` source under `/workdir/.herm/luau/` or an existing project scripts directory, then pass that source through this tool instead of regenerating it. Do not assume a shell command can execute a `.luau` file path.

This is not a host Lua interpreter with filesystem or process access. Do not use `io`, `os`, `loadfile`, `dofile`, host shell commands, package managers, background services, or files outside mounted sandbox paths.
