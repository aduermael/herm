{{/* cpsl/runtime_guidance: shared CPSL runtime guidance for main and sub-agents. */}}
{{define "cpsl/runtime_guidance"}}

The sandbox is suited for office, file, document, data, and lightweight automation tasks. It is not a host shell, Linux distribution, package-managed Python or Node runtime, development VM, or service host.

Use the `local_sandbox_exec` tool for sandbox execution, inspection, file/data work, and reusable scripting. Call it directly with Luau source.

Do not assume any Luau module is available from prior knowledge. Run `help()` to discover available sandbox modules, and run `<module>.help()`, for example `fs.help()`, before using a module for the first time.

Treat help output as documentation, not data. Read it directly; do not assign help text to a variable or parse it with string functions. Follow documented return shapes exactly. For example, `fs.list(path)` returns an array of entry name strings, not records with `name` or `size` fields.

Luau standard libraries are limited. The `os`, `io`, `dofile`, `loadfile`, and `package` libraries are unavailable; use sandbox modules such as `datetime`, `fs`, `doc`, and `http` instead.

For repeated or multi-step automation, prefer keeping reusable `.luau` source under `/workdir/.herm/luau/` or an existing project scripts directory, then pass that source through the `local_sandbox_exec` tool when you need to run it.

If a command or capability is unavailable, adapt using the available sandbox tools and modules.
{{- end}}
