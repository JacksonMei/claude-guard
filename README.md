# claude-guard

Claude Code process resource manager plugin — one command to see where your memory goes, and take it back.

**Zero dependencies.** Pure shell, only uses macOS/Linux built-in tools (`ps`, `awk`, `grep`, `kill`).

## Demo

[![asciicast](https://asciinema.org/a/el6tjtE9BRzlKY5m.svg)](https://asciinema.org/a/el6tjtE9BRzlKY5m)

## The Memory Leak Problem

Claude Code spawns dozens of child processes per session — subagents, MCP servers, workers. When sessions end abnormally (terminal force-close, crash, network drop), these processes become **orphans** (PPID=1) and keep consuming RAM/CPU silently.

**How bad is it?**

| Process Type | Typical Size | Behavior |
|---|---|---|
| Subagents (`claude --output-format stream-json`) | 180-300 MB each | Should die with session, often don't |
| MCP servers (`npx mcp-server-*`, `node mcp-*`) | 40-110 MB each | Persist as orphans after crash |
| Worker services (`worker-service.cjs`, `bun worker-service`) | ~100 MB | Daemon mode survives session death |

Over a day with 3-4 sessions, **orphan accumulation easily reaches 4-8 GB** — your machine slows down, fans spin up, and you don't know why.

Related issues:
- [anthropics/claude-code#20369](https://github.com/anthropics/claude-code/issues/20369) — Orphaned subagent leaks memory
- [anthropics/claude-code#22554](https://github.com/anthropics/claude-code/issues/22554) — Subagent processes not terminating on macOS
- [anthropics/claude-code#25545](https://github.com/anthropics/claude-code/issues/25545) — Excessive RAM when idle
- [anthropics/claude-code#4953](https://github.com/anthropics/claude-code/issues/4953) — ~42 GB/hr memory leak from unreleased streaming ArrayBuffers

## What claude-guard Does

A native Claude Code plugin with unified `/guard` command that **finds, visualizes, and kills** leaked processes.

### `/guard ram` — See Where Your Memory Goes

```
❯ /guard ram

=== Claude Code RAM Usage ===

  PID      RSS(MB)   CPU% ELAPSED
  ------- -------- ------ --------------
  7841        116   9.5% 03:39:45
  11557       321  26.0% 03:17:02
  33291        87   0.0% 13:10

  Sessions: 3 total, 525 MB
  ⚠ 3 sessions open! Consider closing idle ones.

  Subagents
  2 subagents, 377 MB, 0.7% CPU
  MCP Servers
  8 processes, 151 MB, 0.0% CPU
  Orphans (PPID=1)
  1 orphans, 36 MB, 0.0% CPU

  Total
  1059 MB (1.0 GB), 29.0% CPU
```

Breaks down memory usage into 4 categories: **Sessions**, **Subagents**, **MCP Servers**, and **Orphans**. Instantly tells you how much Claude Code is consuming and where the waste is.

### `/guard sessions` — Find Idle Sessions Eating RAM

```
❯ /guard sessions

=== Claude Code Active Sessions ===

  PID      TREE_MB   CPU% ELAPSED        STATUS   CHILDREN
  ------- -------- ------ -------------- -------- --------
  7841        125   7.6% 03:39:46       ACTIVE   2 (125 MB tree)
  11557       324  12.7% 03:17:03       ACTIVE   2 (324 MB tree)
  33291       117   0.7% 13:11          [IDLE]   1 (117 MB tree)

  Sessions: 3 total, 1 idle
  Total RAM (with children): 566 MB (0.6 GB)

  ⚠ Close idle sessions to free ~188 MB
```

Tree RSS calculation includes all child processes. **[IDLE]** detection (CPU < 1%) highlights sessions you forgot about.

### `/guard clean` — Kill Orphan Processes

```
❯ /guard clean --dry-run

=== Claude Code Orphan Cleanup ===

  Mode: DRY-RUN (no processes will be killed)
  Pattern fallback: 0 subagents, 1 MCP processes
  [DRY-RUN] Would clean 0 subagents + 1 MCP stragglers
```

Two-phase cleanup:
1. **PGID-based**: Kill entire orphaned process groups (most reliable)
2. **Pattern fallback**: Catch stragglers with PPID=1 that escaped their group

Always use `--dry-run` first to preview. Whitelisted MCP servers (supabase, stripe, context7, claude-mem, chroma-mcp) are **never killed**.

### `/guard auto` — Automatic Guard

```
❯ /guard auto --dry-run

=== Claude Guard ===

  Config: max_sessions=3, idle_threshold=1%, max_rss=4096 MB
  Mode: DRY-RUN

  PID      TREE_MB   CPU% ELAPSED        STATUS
  ------- -------- ------ -------------- --------
  7841        264   7.3% 03:39:49       LIVE
  11557       245  11.4% 03:17:06       LIVE
  33291       118   0.4% 13:15          [IDLE]

  Sessions: 3 total, 0 bloated, 1 idle, 2 live

  ✓ All clear — no sessions to reap.
```

Two-phase automatic management:
1. **Bloated kill**: Sessions exceeding `CC_MAX_RSS_MB` (default: 4096 MB) are killed immediately — addresses the [~42 GB/hr memory leak](https://github.com/anthropics/claude-code/issues/4953)
2. **Idle eviction**: If session count exceeds `CC_MAX_SESSIONS` (default: 3), oldest idle sessions are reaped

### Stop Hook — Automatic Cleanup on Exit

The plugin includes a Stop hook that **automatically cleans up** the current session's process group when Claude Code exits. Whitelisted MCP servers are preserved for other sessions.

Logs: `~/.claude-guard/logs/stop-cleanup.log`

## Install

### As Plugin (recommended)

```bash
git clone https://github.com/JacksonMei/claude-guard.git ~/.claude/plugins/claude-guard
```

Add to `~/.claude/settings.json`:

```json
{
  "enabledPlugins": {
    "claude-guard": true
  }
}
```

### Manual (standalone)

```bash
git clone https://github.com/JacksonMei/claude-guard.git
chmod +x claude-guard/scripts/guard.sh claude-guard/hooks/stop-cleanup.sh

# Run directly
bash claude-guard/scripts/guard.sh ram
bash claude-guard/scripts/guard.sh sessions
bash claude-guard/scripts/guard.sh clean --dry-run
bash claude-guard/scripts/guard.sh auto --dry-run
```

To add the Stop hook manually, add to `~/.claude/settings.json`:

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

## Configuration

Environment variables for `/guard auto`:

| Variable | Default | Description |
|----------|---------|-------------|
| `CC_MAX_SESSIONS` | 3 | Max concurrent sessions before idle eviction |
| `CC_IDLE_THRESHOLD` | 1 | CPU% below which a session is considered idle |
| `CC_MAX_RSS_MB` | 4096 | Tree RSS threshold (MB); sessions exceeding this are killed |

Example — lower threshold for memory-constrained machines:

```bash
export CC_MAX_RSS_MB=2048
```

## How It Works

### Process Detection

| Category | Detection Method |
|----------|-----------------|
| Sessions | TTY-attached `claude` processes (excludes subagents/MCP) |
| Subagents | `claude --output-format stream-json` pattern |
| MCP Servers | `npm exec mcp-*`, `npx mcp-server-*`, `node mcp-server-*`, `worker-service` |
| Orphans | Any of the above with PPID=1 (reparented to init/launchd) |

### Cleanup Strategy

```
Session ends normally
└── Stop hook — kills session's process group via PGID

Session crashes / terminal force-closed
└── /guard clean — PGID group kill + PPID=1 pattern fallback

Memory running away
└── /guard auto — kills bloated (RSS > threshold) + evicts excess idle
```

### Safety

- **PGID-first**: Kills entire process groups reliably, not individual PIDs
- **Whitelist protection**: Shared MCP servers (supabase, stripe, context7, claude-mem, chroma-mcp) are never killed
- **Dry-run by default**: `--dry-run` previews all actions before execution
- **macOS notifications**: Desktop alerts when sessions are reaped

## Project Structure

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
│   └── guard.sh                 # Core script (ram|clean|sessions|auto)
├── LICENSE                      # Apache 2.0
├── README.md
└── CHANGELOG.md
```

## Credits

Inspired by [cc-reaper](https://github.com/theQuert/cc-reaper).

## License

Apache 2.0
