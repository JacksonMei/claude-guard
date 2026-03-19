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
- macOS desktop notifications on session kills
- Plugin manifest and marketplace metadata
