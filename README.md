# claude-guard

Claude Code process resource manager plugin — visualize and manage sessions, subagents, and MCP server processes.

## Problem

Claude Code spawns subagent processes and MCP servers for each session. When sessions end abnormally, these become orphans (PPID=1) consuming RAM/CPU — often 200-400 MB each. Over a day, this accumulates to 7+ GB of wasted memory.

## Solution

A native Claude Code plugin with unified `/guard` command:

| Command | Function |
|---------|----------|
| `/guard ram` | Resource visualization: RAM/CPU by category |
| `/guard clean` | Kill orphan processes (PGID + pattern fallback) |
| `/guard sessions` | List active sessions with idle detection |
| `/guard auto` | Auto-guard: kill bloated + evict idle sessions |

All commands support `--dry-run` for safe preview.

## Install

### Option 1: Plugin (recommended)

Add to your Claude Code settings (`~/.claude/settings.json`):

```json
{
  "enabledPlugins": [
    "/path/to/claude-guard"
  ]
}
```

### Option 2: Manual

```bash
git clone https://github.com/xagent-team/claude-guard.git
chmod +x claude-guard/scripts/guard.sh claude-guard/hooks/stop-cleanup.sh
```

Add the Stop hook to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/path/to/claude-guard/hooks/stop-cleanup.sh",
            "timeout": 15
          }
        ]
      }
    ]
  }
}
```

## Usage

### `/guard ram` — Resource Visualization

Shows RAM/CPU breakdown by category:
- **Sessions**: `claude --dangerously` processes
- **Subagents**: `claude.*stream-json` workers
- **MCP Servers**: npm/npx/node MCP server processes
- **Orphans**: Processes with PPID=1 (reparented to init)

```
=== Claude Code RAM Usage ===

  PID      RSS(MB)   CPU% ELAPSED
  12345      245    2.3% 01:23:45

  Sessions: 2 total, 490 MB
  Subagents: 4 subagents, 720 MB, 8.2% CPU
  MCP Servers: 6 processes, 340 MB, 0.5% CPU
  Orphans (PPID=1): 2 orphans, 180 MB, 0.0% CPU
  Total: 1730 MB (1.7 GB), 11.0% CPU
```

### `/guard sessions` — Session List

Lists active sessions with idle detection and tree RAM:

```
  PID      TREE_MB   CPU% ELAPSED        STATUS   CHILDREN
  12345      580    3.2% 01:23:45       ACTIVE   12 (580 MB tree)
  12346      420    0.0% 03:45:12       [IDLE]    8 (420 MB tree)

  Sessions: 2 total, 1 idle
  Total RAM (with children): 1000 MB (1.0 GB)
```

### `/guard clean` — Orphan Cleanup

Two-phase cleanup:
1. **PGID-based**: Kill entire orphaned process groups
2. **Pattern fallback**: Catch stragglers that escaped their group

```bash
/guard clean --dry-run    # preview first
/guard clean              # actually kill
```

**Whitelisted** (never killed): supabase, @stripe/mcp, context7, claude-mem, chroma-mcp

### `/guard auto` — Automatic Guard

Two-phase session management:
1. **Bloated kill**: Sessions with tree RSS > `CC_MAX_RSS_MB` (default: 4096 MB)
2. **Idle eviction**: If sessions > `CC_MAX_SESSIONS` (default: 3), kill oldest idle

```bash
/guard auto --dry-run     # preview first
/guard auto               # execute
```

### Configuration

Environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `CC_MAX_SESSIONS` | 3 | Max sessions before idle eviction |
| `CC_IDLE_THRESHOLD` | 1 | CPU% below which session is idle |
| `CC_MAX_RSS_MB` | 4096 | Tree RSS threshold (MB) for bloated kill |

## Stop Hook

The plugin includes a Stop hook (`hooks/stop-cleanup.sh`) that automatically cleans up the current session's process group when Claude Code exits. Whitelisted MCP servers are preserved.

Logs are written to `~/.claude-guard/logs/stop-cleanup.log`.

## Architecture

```
claude-guard/
├── .claude-plugin/
│   ├── plugin.json              # Plugin manifest
│   └── marketplace.json         # Marketplace metadata
├── skills/
│   └── guard/
│       └── SKILL.md             # /guard skill definition
├── hooks/
│   ├── hooks.json               # Hook configuration
│   └── stop-cleanup.sh          # Session exit auto-cleanup
├── scripts/
│   └── guard.sh                 # Core script (all subcommands)
├── LICENSE                      # Apache 2.0
├── README.md
└── CHANGELOG.md
```

## Credits

Inspired by [cc-reaper](https://github.com/theQuert/cc-reaper).

## License

Apache 2.0
