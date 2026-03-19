#!/usr/bin/env bash
# claude-guard: Stop hook — clean up current session's process group on exit
# Whitelisted MCP servers are preserved for other sessions.
set -euo pipefail

LOG_DIR="${HOME}/.claude-guard/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/stop-cleanup.log"

MCP_WHITELIST='supabase|@stripe/mcp|context7|claude-mem|chroma-mcp'

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

log "Stop hook triggered (PID=$$, PPID=$PPID)"

# Find the Claude session that is our parent
SESSION_PID=""
CURRENT_PID=$PPID
for _ in 1 2 3 4 5; do
    if [ -z "$CURRENT_PID" ] || [ "$CURRENT_PID" = "1" ] || [ "$CURRENT_PID" = "0" ]; then
        break
    fi
    CMD=$(ps -o command= -p "$CURRENT_PID" 2>/dev/null || true)
    if echo "$CMD" | grep -q "claude --dangerously"; then
        SESSION_PID=$CURRENT_PID
        break
    fi
    CURRENT_PID=$(ps -o ppid= -p "$CURRENT_PID" 2>/dev/null | tr -d ' ' || true)
done

if [ -z "$SESSION_PID" ]; then
    log "No Claude session found in parent chain, skipping cleanup"
    exit 0
fi

log "Found session PID=$SESSION_PID"

# Get the PGID of the session
PGID=$(ps -o pgid= -p "$SESSION_PID" 2>/dev/null | tr -d ' ' || true)

if [ -z "$PGID" ] || [ "$PGID" = "0" ]; then
    log "Could not determine PGID, skipping"
    exit 0
fi

# Kill processes in the group, skipping whitelisted ones
KILLED=0
while IFS= read -r pid; do
    [ -z "$pid" ] && continue
    # Don't kill ourselves or the session itself (it's shutting down on its own)
    [ "$pid" = "$$" ] && continue
    [ "$pid" = "$SESSION_PID" ] && continue

    CMD=$(ps -o command= -p "$pid" 2>/dev/null || true)
    if echo "$CMD" | grep -qE "$MCP_WHITELIST"; then
        log "  Skipping whitelisted: PID=$pid ($CMD)"
        continue
    fi

    kill "$pid" 2>/dev/null && {
        KILLED=$((KILLED + 1))
        log "  Killed PID=$pid"
    } || true
done < <(ps -eo pid,pgid 2>/dev/null | awk -v pgid="$PGID" '$2 == pgid {print $1}')

log "Cleanup done: killed $KILLED processes from PGID=$PGID"
