# Herm Architecture Overview

## System Components

```
┌─────────────────────────────────────────────────────────────────┐
│                         User Input (Terminal)                    │
├─────────────────────────────────────────────────────────────────┤
│                                                                   │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                      App (Main TUI)                       │   │
│  │  • Terminal UI rendering (raw ANSI mode)                 │   │
│  │  • Input handling (keyboard, paste)                       │   │
│  │  • Event loop (stdin, agent, async results)              │   │
│  ├──────────────────────────────────────────────────────────┤   │
│  │ State Management                                          │   │
│  │  • Chat messages (user, assistant, tool calls)           │   │
│  │  • Token counts & costs                                  │   │
│  │  • Config (global + project merged)                      │   │
│  │  • Session ID, workspace info                            │   │
│  │  • Menu states (branches, worktrees, models)             │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                   │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                  Command Dispatch                         │   │
│  │                                                            │   │
│  │  /clear        → Reset conversation                       │   │
│  │  /config       → Open config editor                       │   │
│  │  /model        → Quick model selector                     │   │
│  │  /compact      → Compress conversation                    │   │
│  │  /branches     → Switch git branches (menu)               │   │
│  │  /worktrees    → Manage git worktrees (menu)              │   │
│  │  /session      → Session management (list/load/show)     │   │
│  │  /usage        → Token/cost stats                         │   │
│  │  /shell        → Sandbox/shell mode                       │   │
│  │  /update       → Check for updates                        │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                   │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │            Async Components                               │   │
│  │                                                            │   │
│  │  ┌─────────────────┐  ┌──────────────────────────┐       │   │
│  │  │ Agent Lifecycle │  │ Initialization (async)   │       │   │
│  │  │                 │  │ • Config loading         │       │   │
│  │  │ • Start agent   │  │ • API client setup       │       │   │
│  │  │ • Listen events │  │ • Model fetch            │       │   │
│  │  │ • Drain events  │  │ • Container readiness    │       │   │
│  │  │ • Handle approva│  └──────────────────────────┘       │   │
│  │  │ • Stop agent    │                                     │   │
│  │  └─────────────────┘  ┌──────────────────────────┐       │   │
│  │                       │ Timers                   │       │   │
│  │  ┌──────────────────┐ │ • agentTicker (status)  │       │   │
│  │  │ Sub-agents       │ │ • toolTimer (elapsed)   │       │   │
│  │  │                  │ │ • commitInfoTicker      │       │   │
│  │  │ • Track state    │ └──────────────────────────┘       │   │
│  │  │ • Display status │                                    │   │
│  │  │ • Freeze time    │                                    │   │
│  │  │ • Keep draining  │                                    │   │
│  │  └──────────────────┘                                    │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                   │
└─────────────────────────────────────────────────────────────────┘
         ↓                              ↓
    ┌─────────────────────────────────────────┐
    │      langdag.com (LLM Abstraction)      │
    │                                          │
    │  • Client: Multi-provider wrapper       │
    │  • ModelCatalog: Pricing, metadata      │
    │  • Event stream: Agent execution        │
    │  • Token tracking: Usage metrics        │
    └─────────────────────────────────────────┘
         ↓
    ┌─────────────────────────────────────────┐
    │    LLM Provider APIs                    │
    │                                          │
    │  • Anthropic (Claude)                   │
    │  • OpenAI (GPT-4)                       │
    │  • Google Gemini                        │
    │  • Grok (xAI)                           │
    └─────────────────────────────────────────┘
         ↓
    ┌─────────────────────────────────────────┐
    │      ContainerClient (Docker)           │
    │                                          │
    │  • Lifecycle management                 │
    │  • Image pulling/building               │
    │  • Dockerfile generation (devenv)       │
    │  • Status reporting                     │
    └─────────────────────────────────────────┘
         ↓
    Docker Container (Agent Execution)
```

---

## Event Loop Architecture

```
Main Event Loop
│
├─ Agent Running: Select on (stdin, agent events, async results)
│  │
│  ├─ Byte from stdin → handleByte()
│  │
│  ├─ Agent Event → handleAgentEvent()
│  │   ├─ EventStart
│  │   ├─ EventThinking
│  │   ├─ EventToolCall
│  │   ├─ EventApproval
│  │   ├─ EventDone
│  │   └─ (drain sub-agent events)
│  │
│  └─ Async Result → handleResult()
│      ├─ initMsg (config, models, container)
│      ├─ resizeMsg (terminal resize)
│      └─ compactResult (conversation compression)
│
├─ Agent Stopped + Sub-agents Active: Keep draining events
│  │
│  └─ Until all sub-agents complete
│
└─ Idle: Select on (stdin, async results)
   └─ Wait for next user input or async completion
```

---

## File Organization

```
cmd/herm/
├── main.go                          # Entry point, App struct, event loop
│
├── commands.go                      # Slash command dispatch (/clear, /config, etc.)
├── configeditor.go                  # /config interactive editor UI
│
├── agent.go                         # Agent lifecycle, tool calling
├── subagent.go                      # Sub-agent tracking & display
├── background.go                    # Background task execution
│
├── input.go                         # Terminal input handling
├── agentui.go                       # Agent status rendering (animated)
├── render.go                        # Chat rendering, layout
├── style.go                         # ANSI styles, colors
│
├── config.go                        # Config loading/merging (global + project)
├── models.go                        # Model catalog, resolution
├── skills.go                        # Tool/skill definitions
│
├── container.go                     # Docker client, image management
├── dockerfiles.go                   # Dockerfile generation (devenv)
│
├── filetools.go                     # File operations, attachments
├── history.go                       # Input history (up/down arrows)
├── tree.go                          # Directory tree formatting
├── worktree.go                      # Git worktree management
├── manifest.go                      # Project manifest reading
│
├── content.go                       # Message content parsing
├── markdown.go                      # Markdown rendering
├── trace.go                         # JSON trace collection (debug)
│
└── *_test.go                        # Test files for above modules

cmd/debug/
└── main.go                          # Keystroke debugger binary
```

---

## Data Flow: Chat Message

```
User Types Message
    ↓
Input Buffer ([]rune)
    ↓
User Presses Enter
    ↓
handleEnter() [main.go]
    ├─ Handle slash commands → handleCommand()
    │  └─ Return to render
    │
    └─ Regular message
        ├─ Add to messages: chatMessage{kind: msgUser}
        ├─ Call startAgent(text)
        │
        └─ Agent Starts
            ├─ Create Agent struct (from agent.go)
            ├─ Start event listener goroutine
            ├─ Start agentTicker for status animation
            │
            ├─ Agent Events:
            │  ├─ EventThinking → Update streamingText
            │  ├─ EventToolCall → Create chatMessage{kind: msgToolCall}
            │  ├─ EventToolResult → Append to messages
            │  ├─ EventUsage → Update token counts
            │  ├─ EventDone → Stop ticker, finalize
            │  └─ Sub-agent events → Update subAgents map
            │
            ├─ Render on each event
            │  ├─ Redraw messages
            │  ├─ Show streaming text
            │  ├─ Show tool calls in progress
            │  ├─ Render agent status timer
            │  └─ Render input line
            │
            └─ Agent Complete
                ├─ Set agentRunning = false
                ├─ Freeze agentElapsed time
                ├─ Keep draining sub-agent events
                └─ Return to idle (wait for next input)
```

---

## Configuration System

```
Global Config (~/.herm/config.json)
├─ API Keys
├─ Model
├─ Exploration
├─ Tool Config
└─ UI Preferences

         ↓ (merge)

Project Config (.herm/config.json in repo)
├─ Override Model
├─ Override Tools
└─ Project-Specific Settings

         ↓ (App.config = merged result)

Effective Config (used for decisions)
├─ resolveActiveModel(models)
├─ resolveExplorationModel(models)
└─ Tool resolution
```

---

## State Lifecycle

### Initialization Phase
```
newApp()
    ↓
startInit() [async]
    ├─ Load global config
    ├─ Detect git repo, load project config
    ├─ Merge configs
    ├─ Create langdag.Client with API key
    ├─ Fetch models from provider
    ├─ Initialize ContainerClient
    └─ Send initMsg results to App
    
App listens on resultCh
    ├─ Config ready
    ├─ Client ready
    ├─ Models ready
    ├─ Container ready (or error)
    └─ Render initial state
```

### Chat Phase
```
Agent Running
├─ Listen for stdin (input)
├─ Listen for agent events
├─ Listen for async results
├─ Render on every change
└─ Manage timers (agent status, tool timer)

Main Agent Stops
├─ If sub-agents active:
│  └─ Keep draining their events
└─ Else:
   └─ Return to idle (await next user input)
```

### Cleanup Phase
```
User presses Ctrl+C (or quit)
    ↓
cleanup()
    ├─ Stop all timers
    ├─ Cancel agent if running
    ├─ Close stdin reader
    ├─ Restore terminal state
    └─ Print session footer
```

---

## Key Abstractions

### `Agent` (agent.go)
- Represents one agent execution lifecycle
- Manages event channel streaming
- Tracks node ID (for conversation tree)
- Implements tool calling and approval flow

### `chatMessage` (main.go)
- Represents one message in conversation
- Kinds: user, assistant, tool call, tool result, info, error
- Stores: content, duration, error flag, tool name

### `Config` / `ProjectConfig` (config.go)
- Serializable config structures
- Global: `~/.herm/config.json`
- Project: `.herm/config.json`
- Merged for effective config

### `subAgentDisplay` (subagent.go)
- Tracks display state for background sub-agents
- Stores: elapsed time, status, frozen flag
- Used for real-time rendering in chat

### `ModelDef` (models.go)
- Model metadata: ID, name, provider, context window
- Pricing: input/output/cache tokens
- Used for cost calculations and resolution

---

## Rendering Pipeline

```
on Event/Update
    ↓
App.render()
    ├─ Get terminal dimensions
    ├─ Calculate layout
    │  ├─ Message area (scrollable)
    │  ├─ Agent status (if running)
    │  ├─ Input line (bottom)
    │  └─ Menu overlay (if active)
    │
    ├─ Format messages
    │  ├─ User messages (blue)
    │  ├─ Assistant messages (streaming)
    │  ├─ Tool calls (highlight)
    │  ├─ Tool results (code blocks)
    │  └─ Info/error messages (colors)
    │
    ├─ Handle scrolling
    │  ├─ scrollShift (rows scrolled off top)
    │  ├─ Preserve bottom when new content
    │  └─ Auto-scroll to latest
    │
    ├─ Render sub-agent status
    │  ├─ Per-agent elapsed time
    │  ├─ Status text
    │  └─ Frozen time indicator
    │
    └─ Clear & print to terminal
        └─ Position cursor at input start
```

---

## Performance Considerations

### Event Draining
- `drainAgentEvents()` - Process all pending events without blocking
- Prevents event queue buildup during fast operations
- Enables responsive UI during agent execution

### Debouncing
- Terminal resize: 150ms debounce
- Prevents excessive re-rendering on rapid window changes

### Timer Management
- `agentTicker` - Only active while agent running
- `toolTimer` - Only active for specific tool execution
- Timers stopped and reset on agent completion

### Sub-agent Lifecycle
- Keep draining events after main agent stops
- Allows live display of background work
- Stops only when all sub-agents finish

---

## Integration Points

### With langdag.com
- Provides LLM client abstraction
- Returns event stream (ThinkingEvent, ToolCallEvent, etc.)
- Tracks token usage per event
- Handles provider authentication

### With Docker
- `ContainerClient` manages lifecycle
- Pulls/builds project-specific images
- Generates Dockerfiles dynamically (devenv)
- Reports container status to UI

### With Git
- Detects repo root (for project config)
- Lists branches (`/branches`)
- Lists worktrees (`/worktrees`)
- Switches branches and worktrees

### With System
- Terminal resize signals (SIGWINCH)
- Raw mode for keyboard input
- Clipboard for paste mode
- File system for config and attachments
