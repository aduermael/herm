# Herm CLI - Quick Start Guide

## Installation

```bash
git clone --recurse-submodules https://github.com/aduermael/herm
cd herm
go build -o herm ./cmd/herm
./herm
```

**Requirements:** Go 1.24+, Docker for the default container backend. For CPSL
local sandbox mode, see [`CPSL_BUILD.md`](CPSL_BUILD.md). For host naked mode,
see `--naked` below.

If you already cloned without submodules, run `git submodule update --init --recursive` before building.

---

## Basic Usage

### Start Interactive Terminal UI
```bash
./herm
```
Opens full TUI with chat interface. Use Ctrl+C to exit.

### Submit a Single Prompt (Headless)
```bash
./herm --prompt "write a Python script to sort a list"
```
- Non-interactive mode
- Submits prompt, waits for completion
- Outputs results to stdout
- Exits automatically
- Debug trace path printed to stderr

### Show Version
```bash
./herm --version
# Output: herm dev (container: herm-latest)
```

### Run Without Docker Or CPSL
```bash
./herm --naked
```
Runs commands on the host through a workspace-scoped sandbox. Requires
`sandbox-exec` on macOS or `bwrap` (bubblewrap) on Linux. New command segments
and outside-workspace paths prompt for approval. Always-approved permissions are
saved in `.herm/permissions.json`, which can include user-edited
`command_regexes` and `path_regexes`.

### Enable Debug Mode
```bash
./herm --debug
```
Enables detailed logging for troubleshooting.

---

## First Time Setup

1. **Start herm:**
   ```bash
   ./herm
   ```

2. **Add API Key:**
   - Type `/config`
   - Navigate to API Keys tab
   - Enter your Anthropic/OpenAI/Gemini/Grok key
   - Press Enter to save
   - Press Ctrl+C to exit config

3. **Start Chatting:**
   - Type your first prompt
   - Press Enter
   - Watch the agent work

---

## Quick Commands (Type in Chat)

| Command | What it does |
|---------|-------------|
| `/config` | Add API keys, change default model |
| `/model` | Quick model switcher |
| `/clear` | Reset conversation |
| `/compact` | Compress long conversations |
| `/usage` | Show token and cost stats |
| `/branches` | Switch git branches |
| `/worktrees` | Manage git worktrees |
| `/session list` | See saved conversations |
| `/session load <id>` | Resume conversation |

---

## Common Workflows

### 1. Coding Task
```
$ ./herm
[Type:]  Write a REST API in Python
[Agent] Creates code, runs tests, fixes issues
[Type:] /usage  # See how many tokens used
[Type:] /compact  # Save tokens before continuing
[Type:] Refactor the error handling
```

### 2. Multi-Branch Development
```
$ ./herm
[Type:] /branches
[Select:] feature-x
[Agent] Continues in feature-x context
[Type:] /branches
[Select:] main
[Agent] Switches to main context
```

### 3. Experiment with Different Models
```
$ ./herm
[Type:] /model
[Select:] gpt-4-turbo
[Type:] Solve this algorithm problem
[Type:] /model
[Select:] claude-3.5-sonnet
[Type:] Try a different approach
```

### 4. Save Conversation for Later
```
$ ./herm
[Type:] Let's build a game
[Type:] Implement the game loop
[Type:] Press Ctrl+C to exit (auto-saved as session)
$ ./herm
[Type:] /session list
[Select:] your-recent-session
[Type:] Now continue building...
```

### 5. Long Research Session
```
$ ./herm
[Type:] Research how to implement caching
[Type:] Show code examples
[Type:] /compact focus on performance
[Type:] Continue with optimization strategies
```

---

## Working with Files

### Attach a File
```
[Type:] Let's review this: 
[Paste:] /path/to/file.py
[Agent] Analyzes and suggests improvements
```

### Screenshot Attachment
- Copy screenshot to clipboard
- In herm, type your message
- Paste with Ctrl+Shift+V (or system paste)
- Agent analyzes the image

### File Operations
Agent can:
- Read/write files (in container)
- Create new files
- Edit existing files
- Run commands (git, npm, etc.)

**Important:** Changes happen in container, not your host!

---

## Container Behavior

### What's Containerized?
- ✅ All agent code execution
- ✅ File operations
- ✅ Package installations
- ✅ Build processes
- ✅ Testing

### What's NOT Containerized
- ❌ herm binary itself
- ❌ Configuration files
- ❌ Conversation history
- ❌ Terminal rendering

### Container Image
- Pulled/built on first use
- Cached for reuse
- Project-specific (per git repo)
- Can be extended with devenv

---

## Configuration Files

### Global Config
Location: `~/.herm/config.json`

```json
{
  "active_model": "claude-3.5-sonnet",
  "api_keys": {
    "anthropic": "sk-ant-...",
    "openai": "sk-..."
  }
}
```

### Project Config
Location: `.herm/config.json` (in repo root)

```json
{
  "active_model": "gpt-4-turbo",
  "exploration_model": "gpt-3.5-turbo"
}
```

**Merge order:** Global first, then project overwrites

---

## Keyboard Shortcuts

### Input Line
- `Ctrl+A` → Start of line
- `Ctrl+E` → End of line
- `Ctrl+K` → Delete to end
- `Ctrl+U` → Delete to start
- `Ctrl+W` → Delete word
- `Ctrl+R` → Search history
- `↑/↓` → Navigate history

### Navigation
- `Tab` → Autocomplete command
- `Enter` → Submit

### Menu Selection
- `↑/↓` → Navigate menu
- `Enter` → Select item
- `Esc` → Close menu

### Special
- `Ctrl+C` → Quit herm
- `Esc` → Stop agent (press twice)

---

## Troubleshooting

### "No API key configured"
```
→ Type: /config
→ Add your API key
→ Try again
```

### "Error pulling container"
```
→ Check Docker is running
→ Check internet connection
→ Try: docker pull <image-name>
```

### "Command not found in container"
```
→ Package not installed in container
→ Agent can install it automatically
→ Or: ask agent to use a different tool
```

### Model not appearing
```
→ Type: /config
→ Check API key is correct
→ Check model name is spelled right
→ Try: /model to see available models
```

### Stuck or slow
```
→ Press Esc to stop current operation
→ Press Esc again to force quit
→ Then type Ctrl+C to exit herm
```

---

## Tips & Tricks

1. **Save time with `/compact`:**
   - Use when conversation gets long
   - Saves tokens for continued work
   - `$ /compact focus on authentication`

2. **Check costs with `/usage`:**
   - See session-wide spending
   - Per-model breakdown
   - Context window percentage

3. **Switch models mid-conversation:**
   - `/model` to pick new model
   - Agent continues with new model
   - Can A/B test different approaches

4. **Use worktrees for parallel work:**
   - `/worktrees` to create/switch
   - Agent continues in new context
   - Original work preserved

5. **Keep configs in git:**
   - Commit `.herm/config.json` to repo
   - Team members share same settings
   - Keep API keys in global config (git-ignored)

6. **Debug agent work:**
   - Run `./herm --debug` for detailed logs
   - Use `/usage` to trace token consumption
   - Check debug traces for event details

---

## Debug Binary

```bash
go build -o debug ./cmd/debug
./debug
```

Shows raw bytes of each keystroke. Useful for:
- Testing keyboard input
- Debugging modifier keys
- Verifying terminal compatibility

---

## Command Examples

### Reset Everything
```
/clear
```

### See Tokens Used
```
/usage
```

### Check Updated Available
```
/update
```

### List Tools Available
Look for `# Tools:` section in agent response

### Switch to Project Config
```
/config
→ Tab to "Project" tab
→ Change "Model"
```

---

## Exit Strategies

- **Normal exit:** Ctrl+C (once)
- **Force exit:** Ctrl+C (twice)
- **Stop agent:** Esc (once), or Ctrl+C while agent running
- **Force quit agent:** Esc (twice)

---

## File Attachments

Herm allows attaching files via paste. Max 20 MB.

Example workflow:
```
[Type:] Review my code:
[Paste:] /full/path/to/main.py
[Type:] What can be improved?
[Agent] Analyzes and suggests changes
```

---

## Advanced: Headless Mode in Scripts

```bash
#!/bin/bash
RESULT=$(./herm --prompt "write a function that reverses a string" 2>&1)
echo "$RESULT"
```

Capture output:
```bash
DEBUG_FILE=$(./herm --prompt "test" 2>&1 | grep "^debug:" | cut -d' ' -f2)
echo "Trace: $DEBUG_FILE"
```

---

## Session Persistence

Conversations auto-save with unique session IDs.

**Resume session:**
```
/session list
/session load 8f3e4a9c
```

**View session info:**
```
/session show
```

---

## Model Selection Priority

```
Model (from config)
    ↓
Exploration (cheaper, for /compact)
    ↓
Falls back to Model if not set
```

---

## Rate Limits & Timeouts

- Initialization: 60 second timeout
- API calls: Provider-specific limits
- Container pull: ~1-5 minutes (cached after)

If stuck, press Ctrl+C and try again.

---

## System Requirements

- **OS:** macOS (tested), Linux, Windows (WSL2)
- **Go:** 1.24+
- **Docker:** Latest stable for the default container backend
- **CPSL mode:** Native build tools and Rust; see [`CPSL_BUILD.md`](CPSL_BUILD.md)
- **Internet:** For API calls
- **Terminal:** ANSI support
- **Disk:** ~1GB for container images

---

## Support

- GitHub: https://github.com/aduermael/herm
- Issues: Report bugs on GitHub
- Prompts: Edit `prompts/` directory
- Dockerfiles: Edit `cmd/herm/dockerfiles/` directory

All customizable!
