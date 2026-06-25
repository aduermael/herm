# Herm CLI Structure and Entry Points

## Project Overview

**Herm** is a containerized coding agent CLI that runs AI-powered commands in isolated Docker containers. It's built in Go (1.24+) and provides a full-featured terminal UI for multi-turn conversations with AI agents.

### Key Characteristics
- **Containerized by default**: All commands run in Docker, nothing touches the host
- **Multi-provider support**: Anthropic, OpenAI, Gemini, Grok
- **Self-building dev environments**: Dynamically generates Dockerfiles for project-specific needs
- **100% open-source**: All system prompts visible
- **Two operation modes**: Interactive TUI (default) and headless (with `--prompt`)

---

## Binaries Built from cmd/

### 1. **cmd/herm/main.go** - Main Application
The primary binary providing the interactive terminal UI and agent orchestration.

**Architecture:**
- Full terminal UI using raw mode with ANSI escape codes
- Event-driven architecture with async initialization
- Agent lifecycle management with sub-agent support
- Config management (global + project-level)
- Integration with langdag.com for LLM provider abstraction

**Main Modes (appMode):**
- `modeChat` - Interactive conversation with AI agent (default)
- `modeConfig` - Configuration editor (global and project settings)
- `modeModel` - Quick model selector
- `modeWorktrees` - Git worktree management
- `modeBranches` - Git branch selector

---

## CLI Entry Points and Flags

### Command-Line Flags (cmd/herm)

```bash
herm [options]
```

**Available flags:**
- `--version` / `-v` - Display version and selected backend label, then exit
- `--debug` - Enable debug logging (sets `app.cliDebug = true`)
- `--prompt <text>` - Run in headless mode: submit prompt and exit (non-interactive)
- `--cpsl <path>` - Run with a CPSL local sandbox library instead of Docker
- `--naked` - Run on the host with workspace-scoped sandboxing instead of Docker or CPSL

**Mode Selection:**
```go
if app.cliPrompt != "" {
    app.headless = true
    return app.RunHeadless()  // Non-interactive mode
}
return app.Run()  // Interactive TUI mode
```

**Examples:**
```bash
herm                           # Start interactive TUI
herm --version                 # Show version
herm --debug                   # Run with debug logging enabled
herm --prompt "write a script" # Headless: submit prompt and exit
```

---

## Interactive Mode: Slash Commands

Accessible in chat mode using `/` prefix with autocomplete.

### Command List

**`/branches`**
- List and switch git branches in current worktree
- Shows interactive menu for branch selection
- Updates workspace status on successful checkout

**`/clear`**
- Reset conversation state completely
- Clears all messages, token counters, agent state
- Finalizes and flushes debug trace file
- Preserves config and models
- Resets: messages, cost, tokens, sub-agents, elapsed time

**`/compact [focus_hint]`**
- Summarize conversation history to reduce token usage
- Optional focus hint for selective summarization
- Uses cheaper "exploration model" if configured
- Maintains conversation continuity via node tree
- Output: "Compacted: X nodes → summary + Y recent nodes"

**`/config`**
- Open configuration editor
- Tabs: Global, Project-specific, Model settings
- Edit API keys, model selections, tool configurations
- Save changes back to `~/.herm/config.json` and `.herm/config.json`

**`/model`**
- Quick jump to model selection screen
- Auto-opens project config tab if in a repo, else global
- Cursor starts on "Model" field

**`/worktrees`**
- Manage git worktrees in current project
- Shows status (active, dirty) for each worktree
- Option to create new worktree (prompted for name)
- Switches workspace to selected worktree

**`/shell`**
- Enter dedicated command interpreter
- In local sandbox mode, defaults to Luau; use `/shell --bash` for Bash-compatible input
- In container mode, enters the container shell
- In naked mode, shell mode is unavailable; host commands run through approved `bash` tool calls
- Return to chat mode to exit

**`/session`** *(with subcommands)*
- `/session list` - List saved conversation sessions
- `/session load <session_id>` - Resume a previous session
- `/session show` - Display current session info
- Enables conversation persistence and resumption

**`/usage`**
- Display comprehensive token and cost statistics
- Session-level breakdown (LLM calls, input/output tokens, cache reads, cost)
- Per-tool call statistics (count, bytes, token estimate)
- Conversation-level stats from node tree
- Context window utilization percentage

**`/update`**
- Check for and apply application updates
- Updates to latest version if available

---

## Headless Mode (--prompt flag)

**Execution Flow:**
1. Initializes config, API client, models, container (with 60s timeout)
2. Submits prompt as single user message
3. Waits for agent to complete (including all sub-agents)
4. Outputs results to stdout
5. Writes debug trace file path to stderr

**Use Cases:**
- CI/CD integration
- Script automation
- Batch processing
- Server-side execution

**Stderr Output:**
```
debug: /path/to/trace-file.json
```

---

## Debug Binary (cmd/debug/main.go)

**Purpose:** Terminal keystroke debugger for troubleshooting key bindings

**Usage:**
```bash
./debug
```

**Output:** For each keystroke, prints:
- Raw bytes in hex format: `bytes=[% x]`
- UTF-8 decoded text if valid: `text="..."`
- Example: `bytes=[1b 5b 41]  text="[A"` (up arrow key)

**Exit:** Press Ctrl+C

---

## Application Architecture

### Event Loop (Run method)

**Selection Logic:**
```
If agent running:
  - Listen on: stdin, agent events, async results
  
Else if sub-agents still active:
  - Keep draining sub-agent events for live display
  
Else:
  - Listen on: stdin, async results only
```

### Key Components

| Component | Purpose |
|-----------|---------|
| `resultCh` | Async initialization results (models, config, container) |
| `stdinCh` | Input byte stream from reader goroutine |
| `agent.Events()` | Main agent and sub-agent event stream |
| `agentTicker` | Animated agent status display while running |
| `toolTimer` | Live elapsed time display for tool execution |
| `sigWinch` | Terminal resize handler (debounced 150ms) |

### State Management

**Persistent State:**
- Session ID (random 8-byte hex)
- Messages (chat history)
- Token counts (session and conversation-level)
- Model selections (resolved from config)
- Worktree path and branch
- Sub-agent display state

**Ephemeral State:**
- Streaming text buffer
- Pending tool calls
- Menu states (branches, worktrees, models)
- Config editor draft

---

## Configuration System

### Merge Strategy
```
Global Config (~/.herm/config.json)
      ↓
   (merge)
      ↓
Project Config (<repo>/.herm/config.json)
      ↓
   = Effective Config
```

### API Initialization
- Async loading during startup
- Models fetched from configured provider
- Waits for config ready + langdagClient + models before accepting chat

### Model Resolution
```
config.resolveActiveModel(models)     // Primary model for chat
config.resolveExplorationModel(models) // Cheaper model for compact, summarization
```

---

## Integration with langdag.com

**Role:** LLM provider abstraction library

**Provides:**
- `langdag.Client` - Multi-provider API wrapper
- `langdag.ModelCatalog` - Model metadata and pricing
- Event streaming for agent execution
- Token usage tracking (input, output, cache read)

**Providers Supported:**
- Anthropic (Claude)
- OpenAI (GPT-4, etc.)
- Google Gemini
- Grok (xAI)

---

## Container Integration

**ContainerClient:** Manages Docker lifecycle
- Checks container readiness on startup
- Pulls/builds project-specific images
- Reports status and errors to UI
- Supports dynamic Dockerfile generation (devenv)

**Status Reporting:**
- `containerReady` - Successfully initialized
- `containerErr` - Initialization failure
- `containerStatusText` - Display message ("Pulling...", "Ready", etc.)
- `containerImage` - Runtime image name

---

## Advanced Features

### Sub-Agent Display
- Real-time rendering of background sub-agent progress
- Per-agent tracking: elapsed time, status
- Timer freeze on completion
- Display ordering: sub-agents above main streaming text

### Approval System
- Pause elapsed time during approval wait
- Track approval duration separately
- Resume timer on approval resolution

### Session Tracing
- JSON trace file collection (`traceCollector`)
- Per-conversation trace files
- Finalized on `/clear` command
- Path printed to stderr for tooling

---

## Version and Container Info

**Version Variable:** `cmd/herm/main.go:24`
```go
var Version = "dev"
```

**At Runtime:**
```bash
$ herm --version
herm dev (container: <hermImageTag>)
```

The container tag is embedded from build time (`hermImageTag` constant).

---

## Summary

Herm provides a sophisticated containerized AI coding agent with:
1. **Interactive CLI** with full TUI and slash commands for workflow control
2. **Headless mode** for automation and CI/CD
3. **Multi-provider** LLM support with per-project configuration
4. **Container safety** - all execution isolated
5. **Debug tooling** for troubleshooting (debug binary)
6. **Event-driven** architecture for responsive UX with async initialization
7. **Session persistence** and conversation compaction for long workflows

The main binary implements the complete TUI, agent orchestration, and command dispatch, while the debug binary assists with terminal input troubleshooting.
