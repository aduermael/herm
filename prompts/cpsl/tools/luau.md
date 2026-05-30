---
name: luau
description: Run native Luau source in CPSL at /workdir
runs_on: cpsl
---

Runs native Luau inside the CPSL local sandbox. The current folder is mounted at `/workdir`. Output is truncated to 80 lines / 12KB (head+tail).

Use this as the primary CPSL execution tool. CPSL modules are available as globals; call `help()` to list modules and `<module>.help()` before using a module, for example `fs.help()` or `json.help()`.

Prefer Luau and CPSL modules for structured file, document, data, network-policy, and automation work. For repeated or multi-step automation, write reusable `.luau` scripts under `/workdir/.herm/cpsl/` or an existing project scripts directory, then execute the script logic through this tool instead of repeating long inline snippets.

This is not a host Lua interpreter with filesystem or process access. Do not use `io`, `os`, `loadfile`, `dofile`, host shell commands, package managers, background services, or files outside mounted sandbox paths.
