# Changelog

## [1.0.0] - 2026-03-19

### Added
- `/guard ram` — RAM/CPU usage visualization by category (sessions, subagents, MCP, orphans)
- `/guard clean` — Orphan process cleanup with PGID-based kill + pattern fallback
- `/guard sessions` — Active session list with idle detection and tree RAM calculation
- `/guard auto` — Automatic guard with bloated kill + idle eviction
- `--dry-run` support for `clean` and `auto` commands
- Stop hook for automatic session cleanup on exit
- MCP whitelist protection (supabase, stripe, context7, claude-mem, chroma-mcp)
- Configurable thresholds via environment variables
- macOS desktop notifications on session kills (auto-skipped on Linux)
- Plugin manifest and marketplace metadata

### Fixed (during iterative testing)
- Session detection: replaced `claude --dangerously` pattern with TTY-based detection
  to match real Claude sessions that run as bare `claude` on terminal
- Exit code stability: added `return 0` guards and `{ grep || true; }` wrappers
  to prevent `set -euo pipefail` crashes from zero-match grep pipelines
- PGID loop crash: vanished processes returning empty command caused `grep -q`
  to exit non-zero under `set -e`; added empty-string guard
- Orphan detection: switched from TTY `??` matching to precise PPID=1 filtering
- Whitelist protection: added `grep -vE "$MCP_WHITELIST"` to worker-service kill
  path to prevent killing shared claude-mem daemon
- Empty array safety: guarded `_tree_rss` children loop against `set -u` crash
- Platform compat: wrapped `osascript` calls with `command -v` check for Linux
