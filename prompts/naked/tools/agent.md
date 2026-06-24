---
name: agent
description: Spawn a sub-agent that uses the same naked-mode host sandbox
runs_on: host
---

Spawn a sub-agent with its own context window. Sub-agents inherit the same naked-mode host sandbox and command approval behavior.

Use explore mode for read-only research and general mode for bounded code changes. When spawning multiple general-mode sub-agents, ensure they work on separate files or directories.

**Background mode** (`background: true`):
- Use for independent work while you continue.
- Poll with `agent` status if you need progress.
- Retrieve full output from `.herm/agents/<agent_id>.md` when needed.

**Turn budget:** Explore mode gets __EXPLORE_MAX_TURNS__ turns, general mode gets __GENERAL_MAX_TURNS__ turns. Scope work to fit the budget; split large tasks into focused sub-agents.
