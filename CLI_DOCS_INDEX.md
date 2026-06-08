# Herm CLI Documentation Index

Complete reference documentation for Herm's entry points, commands, and architecture.

---

## Quick Navigation

**Just getting started?** → [`CLI_QUICK_START.md`](CLI_QUICK_START.md) (9 min read)

**Need to know a specific command?** → [`COMMANDS_REFERENCE.md`](COMMANDS_REFERENCE.md) (5 min read)

**Building local sandbox mode?** → [`CPSL_BUILD.md`](CPSL_BUILD.md)

**Want to understand how it works?** → [`ENTRY_POINTS.md`](ENTRY_POINTS.md) + [`ARCHITECTURE.md`](ARCHITECTURE.md) (20 min read)

---

## Documentation Files

### 1. [`CLI_QUICK_START.md`](CLI_QUICK_START.md) - For New Users
**Target audience:** Anyone using Herm for the first time

**Coverage:**
- Installation and setup
- Basic usage (interactive and headless)
- First-time configuration
- Common workflows (coding, multi-branch dev, etc.)
- File attachments
- Keyboard shortcuts
- Troubleshooting
- Examples and tips

**Best for:** Getting up and running, quick reference during first use

---

### 2. [`CPSL_BUILD.md`](CPSL_BUILD.md) - Build Herm With CPSL
**Target audience:** Users building Herm's local sandbox backend from source

**Coverage:**
- Linux and macOS native prerequisites
- Host-native build helper script
- Minimum and all-features CPSL library profiles
- Artifact paths and `herm --cpsl` run commands
- CPSL mode runtime limits

**Best for:** Running Herm without Docker through a native CPSL sandbox library

---

### 3. [`COMMANDS_REFERENCE.md`](COMMANDS_REFERENCE.md) - Command Cheat Sheet
**Target audience:** Users learning or remembering slash commands

**Coverage:**
- Command summary table
- Detailed per-command reference
  - `/branches` - Switch git branches
  - `/clear` - Reset conversation
  - `/compact` - Compress history
  - `/config` - Configuration editor
  - `/model` - Quick model selector
  - `/worktrees` - Manage git worktrees
  - `/shell` - Sandbox/shell mode
  - `/session` - Session management
  - `/usage` - Token/cost stats
  - `/update` - Check for updates
- Keyboard navigation in menus
- Input editing shortcuts
- Command completion
- Error messages and solutions
- Integration with config

**Best for:** Looking up what a command does, or learning all available commands

---

### 4. [`ENTRY_POINTS.md`](ENTRY_POINTS.md) - Technical Reference
**Target audience:** Developers, contributors, tool integrators

**Coverage:**
- Project overview and key characteristics
- Binary structure
  - `cmd/herm/main.go` - Main TUI application
  - `cmd/debug/main.go` - Keystroke debugger
- CLI flags
  - `--version` / `-v`
  - `--debug`
  - `--prompt` (headless mode)
- Interactive mode architecture
  - Main modes (chat, config, model, worktrees, branches)
  - Event loop design
  - State management
  - Component overview
- Headless mode execution
- Container integration
- Session tracing
- Version info

**Best for:** Understanding the command-line interface, debugging CLI issues, integrating Herm into other tools

---

### 5. [`ARCHITECTURE.md`](ARCHITECTURE.md) - Deep Dive into System Design
**Target audience:** Contributors, maintainers, architecture learners

**Coverage:**
- System component diagram
- Event loop architecture
  - Stdin, agent events, async results
  - Sub-agent handling
  - Idle state management
- File organization (all ~50 .go files mapped)
- Data flow: Chat message lifecycle
- Configuration system (merge strategy)
- State lifecycle (initialization, chat, cleanup)
- Key abstractions (Agent, chatMessage, Config, etc.)
- Rendering pipeline
- Performance considerations
  - Event draining
  - Debouncing
  - Timer management
  - Sub-agent lifecycle
- Integration points (langdag.com, Docker, Git, System)

**Best for:** Contributing to Herm, understanding code organization, debugging complex behaviors

---

## Documentation Map

```
New User → CLI_QUICK_START.md
  ├─ Building local sandbox mode? → CPSL_BUILD.md
  ├─ Need to know a command? → COMMANDS_REFERENCE.md
  └─ Want deeper understanding? → ENTRY_POINTS.md
       ├─ CLI flags and modes
       ├─ Configuration system
       └─ Want full architecture? → ARCHITECTURE.md
             ├─ Event loop design
             ├─ State management
             └─ Integration points

Developer → ENTRY_POINTS.md → ARCHITECTURE.md
  ├─ File organization
  ├─ Data flow
  ├─ Key abstractions
  └─ Component interactions
```

---

## Usage Scenarios

### Scenario 1: First Time Using Herm
1. Read: [`CLI_QUICK_START.md`](CLI_QUICK_START.md) - Installation & Setup
2. Follow: First Time Setup section
3. Try: Common Workflows section
4. Reference: [`COMMANDS_REFERENCE.md`](COMMANDS_REFERENCE.md) as needed

### Scenario 2: Building Local Sandbox Mode
1. Read: [`CPSL_BUILD.md`](CPSL_BUILD.md) - Native prerequisites and helper script
2. Run: `scripts/build-cpsl-image.sh` from the Herm checkout
3. Start: Herm with the printed `--cpsl` command
4. Reference: [`COMMANDS_REFERENCE.md`](COMMANDS_REFERENCE.md) for `/shell`

### Scenario 3: Learning a Specific Command
1. Open: [`COMMANDS_REFERENCE.md`](COMMANDS_REFERENCE.md)
2. Search: Command name (e.g., `/compact`, `/usage`)
3. Read: Detailed command section
4. See: Examples and tips

### Scenario 4: Integrating Herm into Automation
1. Read: [`ENTRY_POINTS.md`](ENTRY_POINTS.md) - Headless Mode section
2. Review: CLI flags documentation
3. Understand: Configuration system
4. Reference: [`CLI_QUICK_START.md`](CLI_QUICK_START.md) - Headless Mode in Scripts

### Scenario 5: Contributing to Herm Codebase
1. Start: [`ENTRY_POINTS.md`](ENTRY_POINTS.md) - Binary & Architecture sections
2. Study: [`ARCHITECTURE.md`](ARCHITECTURE.md) - Full system design
3. Reference: File organization and data flow sections
4. Navigate: Source code using documented structure

### Scenario 6: Debugging an Issue
1. Check: [`CLI_QUICK_START.md`](CLI_QUICK_START.md) - Troubleshooting section
2. Try: Commands from [`COMMANDS_REFERENCE.md`](COMMANDS_REFERENCE.md)
3. Investigate: [`ENTRY_POINTS.md`](ENTRY_POINTS.md) - Component descriptions
4. Deep dive: [`ARCHITECTURE.md`](ARCHITECTURE.md) - Event loop and state management

### Scenario 7: Understanding the Event Loop
1. Review: [`ENTRY_POINTS.md`](ENTRY_POINTS.md) - Interactive Mode Architecture
2. Study: [`ARCHITECTURE.md`](ARCHITECTURE.md) - Event Loop Architecture
3. Trace: Data flow sections (Chat Message lifecycle)
4. Reference: File organization for source files

---

## Key Concepts Explained Across Docs

### Configuration System
- **Quick Start:** How to add API keys (CLI_QUICK_START.md)
- **Commands:** `/config` and `/model` commands (COMMANDS_REFERENCE.md)
- **Technical:** Config structure and merge strategy (ENTRY_POINTS.md)
- **Architecture:** Config loading and resolution (ARCHITECTURE.md)

### Model Selection
- **Quick Start:** Switching models with `/model` (CLI_QUICK_START.md)
- **Commands:** `/model` and `/config` usage (COMMANDS_REFERENCE.md)
- **Technical:** Model resolution logic (ENTRY_POINTS.md)
- **Architecture:** Model catalog and cost calculation (ARCHITECTURE.md)

### Session Management
- **Quick Start:** Saving and resuming conversations (CLI_QUICK_START.md)
- **Commands:** `/session` subcommands (COMMANDS_REFERENCE.md)
- **Technical:** Session tracing and persistence (ENTRY_POINTS.md)
- **Architecture:** State lifecycle (ARCHITECTURE.md)

### Agent Execution
- **Quick Start:** How agent works (CLI_QUICK_START.md)
- **Technical:** Agent events and lifecycle (ENTRY_POINTS.md)
- **Architecture:** Event loop and data flow (ARCHITECTURE.md)

### Container Integration
- **Quick Start:** What's containerized (CLI_QUICK_START.md)
- **Technical:** Container integration details (ENTRY_POINTS.md)
- **Architecture:** ContainerClient integration (ARCHITECTURE.md)

### CPSL Local Sandbox
- **Build:** Linux/macOS native build flow (CPSL_BUILD.md)
- **Quick Start:** Docker-free local sandbox pointer (CLI_QUICK_START.md)
- **Commands:** `/shell` behavior in sandbox mode (COMMANDS_REFERENCE.md)

---

## File Statistics

| Document | Lines | Focus | Audience |
|----------|-------|-------|----------|
| CLI_QUICK_START.md | 463 | Usage & setup | End users |
| CPSL_BUILD.md | 136 | Local sandbox build | End users |
| COMMANDS_REFERENCE.md | 250 | Command reference | End users |
| ENTRY_POINTS.md | 330 | Technical overview | Developers |
| ARCHITECTURE.md | 411 | System design | Contributors |
| **Total** | **1,590** | **Complete reference** | **Everyone** |

---

## Quick Lookup Table

| Topic | In CLI_QUICK_START | In COMMANDS_REFERENCE | In ENTRY_POINTS | In ARCHITECTURE |
|-------|-------------------|----------------------|-----------------|-----------------|
| Installation | ✓ | — | — | — |
| Basic usage | ✓ | — | ✓ | — |
| First setup | ✓ | — | — | — |
| CLI flags | ✓ | — | ✓ | — |
| `/branches` | — | ✓ | ✓ | — |
| `/clear` | — | ✓ | ✓ | — |
| `/compact` | ✓ | ✓ | ✓ | — |
| `/config` | ✓ | ✓ | ✓ | ✓ |
| `/model` | ✓ | ✓ | ✓ | ✓ |
| `/session` | ✓ | ✓ | ✓ | ✓ |
| `/usage` | ✓ | ✓ | ✓ | — |
| Event loop | — | — | ✓ | ✓ |
| Configuration | ✓ | ✓ | ✓ | ✓ |
| Headless mode | ✓ | — | ✓ | — |
| Container | ✓ | — | ✓ | ✓ |
| File structure | — | — | ✓ | ✓ |
| Integration | — | — | ✓ | ✓ |
| Keyboard shortcuts | ✓ | ✓ | — | — |
| Troubleshooting | ✓ | ✓ | — | — |
| Examples | ✓ | ✓ | — | — |

---

## Recommended Reading Order

### Path 1: User
1. CLI_QUICK_START.md (read all)
2. COMMANDS_REFERENCE.md (skim, use as reference)

**Time:** 30-45 minutes

### Path 1b: Local Sandbox User
1. CPSL_BUILD.md
2. CLI_QUICK_START.md (First Time Setup)
3. COMMANDS_REFERENCE.md (`/shell` section)

**Time:** 30-45 minutes

### Path 2: Power User
1. CLI_QUICK_START.md (read all)
2. COMMANDS_REFERENCE.md (read all)
3. ENTRY_POINTS.md (sections: Overview, CLI Flags, Advanced Features)

**Time:** 60-90 minutes

### Path 3: Integrator
1. ENTRY_POINTS.md (all sections)
2. CLI_QUICK_START.md (Headless Mode section)
3. ARCHITECTURE.md (Configuration System section)

**Time:** 90 minutes

### Path 4: Contributor
1. ENTRY_POINTS.md (all sections)
2. ARCHITECTURE.md (all sections)
3. Reference CLI_QUICK_START.md and COMMANDS_REFERENCE.md as needed

**Time:** 2-3 hours

### Path 5: Maintainer
1. ARCHITECTURE.md (all sections)
2. ENTRY_POINTS.md (all sections)
3. CLI_QUICK_START.md (Troubleshooting section)
4. COMMANDS_REFERENCE.md (as reference)

**Time:** 3+ hours

---

## Navigating the Source Code

Using these docs, you can navigate the source code:

**Start here:** `cmd/herm/main.go`
- Entry point (line 1096)
- App struct and main event loop
- Run() method (line 305)
- RunHeadless() method (line 449)

**Then explore:**
- `cmd/herm/commands.go` - Slash command handlers
- `cmd/herm/agent.go` - Agent lifecycle
- `cmd/herm/render.go` - Chat rendering
- `cmd/herm/config.go` - Configuration system

**For deep understanding:**
- Review file organization in ARCHITECTURE.md
- Follow data flow diagrams
- Trace event loop in code

---

## Getting Help

**Using Herm?** → Check CLI_QUICK_START.md Troubleshooting section

**Need a command?** → Search COMMANDS_REFERENCE.md

**Contributing?** → Study ENTRY_POINTS.md + ARCHITECTURE.md

**Have questions?** → GitHub Issues: https://github.com/aduermael/herm

---

## Document Maintenance

These documents were created from analysis of:
- `cmd/herm/main.go` - Main application (1131 lines)
- `cmd/herm/commands.go` - Command dispatch (474 lines)
- `cmd/debug/main.go` - Debug binary (48 lines)
- Project structure and README.md

Last updated: April 3, 2026

---

## Quick Reference Commands

```bash
# Start interactive TUI
./herm

# Submit single prompt (headless)
./herm --prompt "your prompt here"

# Show version
./herm --version

# Run with a CPSL local sandbox library
./herm --cpsl "$CPSL_LIB"

# Enable debug mode
./herm --debug
```

In chat:
```
/config     - Configure settings
/model      - Switch model
/clear      - Reset conversation
/compact    - Compress history
/usage      - Show token stats
/branches   - Switch git branch
/worktrees  - Manage worktrees
/session    - Resume conversation
/shell      - Sandbox/shell mode
/update     - Check updates
```

---

## All Documentation Files

1. **CLI_QUICK_START.md** (459 lines) - Getting started guide
2. **COMMANDS_REFERENCE.md** (248 lines) - Command cheat sheet
3. **ENTRY_POINTS.md** (329 lines) - Technical reference
4. **ARCHITECTURE.md** (411 lines) - System design deep dive

**Total:** 1,447 lines of comprehensive documentation
