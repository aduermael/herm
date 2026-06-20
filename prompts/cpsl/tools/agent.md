---
name: agent
description: Spawn a sandbox-safe sub-agent to handle a complex subtask
runs_on: cpsl
---

Spawn a sub-agent with its own context window. Sub-agents inherit the same sandbox-safe prompt and tool set: execution runs in the sandbox with `/workdir` as the workspace, cannot leave the sandbox, and has no host shell or host git tool.

**Modes - you must specify one:**
- `"explore"` - uses a fast, cheap model. For research, search, reading files, investigating issues, gathering information.
- `"general"` - uses the full orchestrator model. For writing files, running sandbox execution cycles, and executing changes.

**When to use:**
- Tasks requiring deep exploration across many files (10+ tool calls) -> `explore`
- Self-contained implementation or automation work that would produce verbose output -> `general`
- Running multiple independent investigations in parallel (spawn several sub-agents) -> `explore`

When spawning multiple general-mode sub-agents, ensure they work on separate files or directories. Parallel edits to the same file can conflict.

**When NOT to use - act directly instead:**
- A single command
- A small edit
- Running one command and interpreting the output
- Any task completable in ~5 or fewer tool calls

**Background mode** (`background: true`):
- The sub-agent runs asynchronously. You get an agent_id immediately and can continue working.
- When the background agent completes, its result is automatically injected into your next LLM context.
- Check status anytime: `agent(agent_id: "<id>", task: "status")` - returns "running" or "completed" with the full result.
- Cannot be combined with agent_id.

**Usage:**
- Provide a clear, self-contained task description. The sub-agent has the same sandbox-safe tools you do but no shared memory.
- Resume a previous sub-agent by passing its agent_id with a new task.

**Reading results:**
- Results have a compact header: `[agent:<id> turns:<N/M> summary:<method>]` followed by an `[output: <path>]` pointer to the full output file.
- `summary:model` - structured summary (STATUS/FILES/FINDINGS/NEXT); usually sufficient to act on.
- `summary:truncated` - naive truncation; inspect the full output file with `local_sandbox_exec`, for example `print(fs.read("/workdir/.herm/agents/<agent_id>.md"))`.
- `[errors: ...]` - sub-agent hit errors; review and consider retrying with a narrower task.
- Turns count LLM response cycles, not individual tool calls (one response with 5 tool calls = 1 turn). N=M means the sub-agent hit its turn limit and may have incomplete results.

**Turn budget:** Explore mode gets __EXPLORE_MAX_TURNS__ turns, general mode gets __GENERAL_MAX_TURNS__ turns. Scope explore tasks to fit within ~75% of the budget + a few turns for synthesis. If a task requires more depth, split it into multiple focused sub-agents.
