---
name: guard
description: Visualize and manage Claude Code process resources (RAM/CPU, sessions, orphan cleanup, auto-guard)
---

# /guard — Claude Code Process Resource Manager

Manage Claude Code sessions, subagents, and MCP server processes.

## Usage

The user invokes `/guard <subcommand>`. Parse the subcommand and execute the corresponding shell script.

## Commands

| Command | Action |
|---------|--------|
| `/guard ram` | Show RAM/CPU usage breakdown by category |
| `/guard clean` | Kill orphan processes (use `--dry-run` to preview) |
| `/guard sessions` | List active sessions with idle detection |
| `/guard auto` | Auto-guard: kill bloated + evict idle (use `--dry-run` to preview) |
| `/guard` (no args) | Show help / command overview |

## Execution

For each subcommand, run the guard.sh script located relative to this plugin:

```bash
# Determine plugin directory
PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"

# Execute the requested subcommand
bash "$PLUGIN_DIR/scripts/guard.sh" <subcommand> [options]
```

### Concrete examples:

**`/guard ram`**
```bash
bash "$PLUGIN_DIR/scripts/guard.sh" ram
```

**`/guard clean --dry-run`**
```bash
bash "$PLUGIN_DIR/scripts/guard.sh" clean --dry-run
```

**`/guard clean`**
```bash
bash "$PLUGIN_DIR/scripts/guard.sh" clean
```

**`/guard sessions`**
```bash
bash "$PLUGIN_DIR/scripts/guard.sh" sessions
```

**`/guard auto --dry-run`**
```bash
bash "$PLUGIN_DIR/scripts/guard.sh" auto --dry-run
```

**`/guard auto`**
```bash
bash "$PLUGIN_DIR/scripts/guard.sh" auto
```

## Important Notes

- `clean` and `auto` without `--dry-run` will **kill processes**. Always recommend `--dry-run` first.
- Whitelisted MCP servers (supabase, stripe, context7, claude-mem, chroma-mcp) are **never killed**.
- The `auto` command uses env vars for config: `CC_MAX_SESSIONS`, `CC_IDLE_THRESHOLD`, `CC_MAX_RSS_MB`.

## Output Format

Present the script output directly to the user. The output includes formatted tables and color codes for terminal display.
