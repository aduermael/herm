# Herm Interactive Commands Reference

Quick lookup table for all interactive slash commands available in chat mode.

## Command Summary

| Command | Purpose | Subcommands | Example |
|---------|---------|-------------|---------|
| `/branches` | Switch git branches | — | `/branches` then select |
| `/clear` | Reset conversation | — | `/clear` |
| `/compact` | Compress conversation history | Optional focus hint | `/compact reduce API calls` |
| `/config` | Open config editor | — | `/config` |
| `/model` | Quick model selector | — | `/model` |
| `/worktrees` | Manage git worktrees | — | `/worktrees` |
| `/shell` | Enter sandbox/shell command mode | `--bash`, `--luau` | `/shell`, `/shell --bash` |
| `/session` | Session management | `list`, `load`, `show` | `/session list` |
| `/usage` | Show token/cost stats | — | `/usage` |
| `/update` | Check for updates | — | `/update` |

---

## Detailed Command Reference

### `/branches`
**Interactive branch switcher**
- Lists all git branches in current worktree
- Menu-based selection with arrow keys
- Updates workspace status on checkout
- Requires: Git repository

### `/clear`
**Reset entire conversation**
- Clears all messages and chat history
- Resets token counts and cost tracking
- Removes all sub-agent state
- Finalizes and flushes debug trace
- Preserves: configuration, models, workspace info
- Best for: Starting fresh conversation on same topic

### `/compact [optional_focus_hint]`
**Summarize conversation to save tokens**
- Compresses older messages into summary
- Keeps recent context intact
- Uses cheaper model if configured (falls back to active model)
- Output: `Compacted: 42 nodes → summary + 8 recent nodes`
- Best for: Long conversations approaching context limits
- Example: `/compact focus on API design`

### `/config`
**Configuration editor**
- **Tabs:**
  - Global: `~/.herm/config.json` (applies everywhere)
  - Project: `.herm/config.json` (applies in current repo)
  - Models: Model-specific settings
- **Fields:** API keys, active model, exploration model, tool configs
- **Navigation:** Tab/Shift-Tab, arrow keys
- **Save:** Enter key after editing field
- Best for: Adding API keys, changing default model

### `/model`
**Quick model selector**
- Opens `/config` directly to model selection
- If in repo: Opens Project tab (priority)
- If standalone: Opens Global tab
- Cursor pre-positioned on "Active Model"
- Best for: One-off model changes without full config editor

### `/worktrees`
**Git worktree manager**
- Lists all worktrees for current project
- Shows: Name, branch, status flags [active] [dirty]
- Options:
  - `+ New worktree` - Create new worktree (prompts for name)
  - Existing worktrees - Switch to selected
- Requires: Git repository
- Best for: Multi-branch development workflows

### `/shell`
**Sandbox command mode**
- Enter dedicated command interpreter
- In local sandbox mode, `/shell` starts a Luau prompt by default
- Use `/shell --bash` for Bash-compatible sandbox input
- In container mode, `/shell` enters the container shell
- Exit: Return to chat mode
- Useful for: Sequential sandbox operations, debugging

### `/session`
**Conversation session management**

#### `/session list`
Lists all saved conversation sessions with IDs and metadata

#### `/session load <session_id>`
Resume a previously saved conversation
- Restores full message history
- Continues from where you left off
- Maintains token counts and statistics

#### `/session show`
Display info about current session
- Session ID, timestamp, message count
- Current model and provider

### `/usage`
**Token and cost statistics**

**Session-level stats:**
- LLM calls (total, main agent only, sub-agents)
- Input tokens with breakdown
- Output tokens with breakdown
- Cache read tokens (if used)
- Total cost in USD
- Tool call summary

**Per-tool breakdown:**
- Tool name, call count, bytes transferred
- Token estimate (~1 token per 4 chars)
- Sorted by bytes (descending)

**Conversation stats:**
- Input/output/cache tokens from node tree
- Cost for current conversation
- Tool result count and bytes

**Context window:**
- Used: tokens from last API call
- Total: model's context window size
- Percentage: `(used / total) × 100%`

### `/update`
**Application updates**
- Checks for newer version available
- Prompts to update if available
- Downloads and installs update

---

## Keyboard Navigation in Menus

When a menu is active (after `/branches`, `/worktrees`, etc.):

| Key | Action |
|-----|--------|
| ↑/↓ | Navigate menu items |
| Enter | Select item and execute |
| Esc | Close menu |
| Page Up/Down | Scroll menu faster |

---

## Input Editing

In main chat input:

| Key | Action |
|-----|--------|
| Ctrl+A | Move to start of line |
| Ctrl+E | Move to end of line |
| Ctrl+K | Kill (delete) to end of line |
| Ctrl+U | Kill from start to cursor |
| Ctrl+W | Delete previous word |
| Ctrl+R | Reverse history search |
| ↑/↓ | Navigate input history |
| Tab | Autocomplete command |

---

## Command Completion

Type `/` to see available commands:
```
/branches   /clear      /compact    /config     /model
/session    /shell      /update     /usage      /worktrees
```

Type `/ses` to filter to matching commands:
```
/session
  ├─ /session list
  ├─ /session load
  └─ /session show
```

---

## Tips & Tricks

1. **Large conversations?** Use `/compact` with a focus hint to save tokens
   - `$ /compact focus on error handling`

2. **Need to switch models?** `/model` is faster than `/config`

3. **Long-running task?** Use `/usage` to monitor context consumption

4. **Multiple branches?** Use `/branches` for quick switching

5. **Save a conversation?** Auto-saved with session ID; use `/session load` later

6. **Clean slate?** Use `/clear` to reset without losing config

---

## Error Handling

**"No workspace path available"**
- `/branches` requires a git repo
- Solution: `cd` to repo root before starting herm

**"Not in a git repository"**
- `/worktrees` requires a git repo
- Solution: Initialize repo or `cd` to existing repo

**"No API client available"**
- `/compact` requires LLM API configured
- Solution: Use `/config` to add API key first

**"No active conversation to compact"**
- `/compact` requires at least one agent response
- Solution: Ask agent something first

---

## Command Lifecycle

```
Start herm
    ↓
Type / → see commands
    ↓
Select command
    ↓
Execute (menu, config editor, or async operation)
    ↓
Return to chat (or /shell for multi-command mode)
```

---

## Integration with Config

Commands that affect configuration:
- `/config` - Edit directly
- `/model` - Switch active model (saves to config)
- `/worktrees` - Switch workspace (updates config path)

Config changes persist:
- Global: `~/.herm/config.json`
- Project: `.herm/config.json` (in repo root)

When using multiple providers, `/config` to set which is active.
