{{/* cpsl/runtime_guidance: shared CPSL runtime guidance for main and sub-agents. */}}
{{define "cpsl/runtime_guidance"}}

The sandbox is suited for office, file, document, data, and lightweight automation tasks. It is not a host shell, Linux distribution, package-managed Python or Node runtime, development VM, or service host.

Use the `local_sandbox_exec` tool for sandbox execution, inspection, file/data work, and reusable scripting. Call it directly with Luau source.

Do not assume any Luau module is available from prior knowledge. Run `help()` to discover available sandbox modules, and run `<module>.help()`, for example `fs.help()`, before using a module for the first time.

For repeated or multi-step automation, prefer keeping reusable `.luau` source under `/workdir/.herm/luau/` or an existing project scripts directory, then pass that source through the `local_sandbox_exec` tool when you need to run it.

If a command or capability is unavailable, adapt using the available sandbox tools and modules.
{{- end}}
