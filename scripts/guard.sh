#!/usr/bin/env bash
# claude-guard: Claude Code process resource manager
# Usage: guard.sh <command> [options]
# Commands: ram, clean, sessions, auto
set -euo pipefail

# ─── Constants ────────────────────────────────────────────────────────────────
VERSION="1.0.0"

# Process detection patterns
# Sessions: claude on a TTY (or with --dangerously), excluding subagents/MCP
PAT_SUBAGENT='claude.*stream-json'
PAT_MCP='npm exec mcp-|npx.*mcp-server|node.*mcp-server|worker-service\.cjs|bun.*worker-service|node.*sequential-thinking|uv.*chroma-mcp|python.*chroma-mcp|npm exec @supabase|npm exec @upstash'
PAT_ALL="claude|${PAT_MCP}"

# Whitelist: long-running shared MCP servers (never killed)
MCP_WHITELIST='supabase|@stripe/mcp|context7|claude-mem|chroma-mcp'

# Default config
: "${CC_MAX_SESSIONS:=3}"
: "${CC_IDLE_THRESHOLD:=1}"
: "${CC_MAX_RSS_MB:=4096}"

# ─── Helpers ──────────────────────────────────────────────────────────────────

# Detect Claude CLI session PIDs: TTY-attached 'claude' processes, excluding subagents/MCP
# Also matches 'claude --dangerously' for backward compat
_get_session_pids() {
    {
        # Method 1: claude processes attached to a real TTY (not "??")
        ps -eo pid,tty,command 2>/dev/null | awk '
            $2 != "??" && /[c]laude/ && !/stream-json/ && !/mcp/ && !/worker-service/ && !/chroma/ && !/snapshot/ {print $1}
        '
        # Method 2: legacy --dangerously pattern (for older Claude versions)
        ps -eo pid,command 2>/dev/null | grep "[c]laude --dangerously" | awk '{print $1}'
    } | sort -un
}

# Calculate tree RSS (MB) for a given PID: process + all descendants
_tree_rss() {
    local pid=$1
    local rss
    rss=$(ps -p "$pid" -o rss= 2>/dev/null | tr -d ' ')
    [ -z "$rss" ] && echo 0 && return

    local tree_kb=$rss
    local children=()
    while IFS= read -r cpid; do
        [ -z "$cpid" ] && continue
        children+=("$cpid")
        local crss
        crss=$(ps -p "$cpid" -o rss= 2>/dev/null | tr -d ' ')
        [ -n "$crss" ] && tree_kb=$((tree_kb + crss))
    done < <(pgrep -P "$pid" 2>/dev/null)

    for cpid in "${children[@]}"; do
        while IFS= read -r gcpid; do
            [ -z "$gcpid" ] && continue
            local gcrss
            gcrss=$(ps -p "$gcpid" -o rss= 2>/dev/null | tr -d ' ')
            [ -n "$gcrss" ] && tree_kb=$((tree_kb + gcrss))
        done < <(pgrep -P "$cpid" 2>/dev/null)
    done

    echo $((tree_kb / 1024))
}

# Kill a process group while preserving whitelisted MCP servers
_pgid_kill() {
    local target_pid=$1
    local dry_run=${2:-false}
    local pgid
    pgid=$(ps -o pgid= -p "$target_pid" 2>/dev/null | tr -d ' ')

    if [ -n "$pgid" ] && [ "$pgid" != "0" ]; then
        while IFS= read -r pid; do
            [ -z "$pid" ] && continue
            local pid_cmd
            pid_cmd=$(ps -o command= -p "$pid" 2>/dev/null)
            if echo "$pid_cmd" | grep -qE "$MCP_WHITELIST"; then
                continue
            fi
            if [ "$dry_run" = "true" ]; then
                echo "    [DRY-RUN] Would kill PID $pid: $(echo "$pid_cmd" | cut -c1-80)"
            else
                kill "$pid" 2>/dev/null || true
            fi
        done < <(ps -eo pid,pgid 2>/dev/null | awk -v pgid="$pgid" '$2 == pgid {print $1}')
    else
        if [ "$dry_run" = "true" ]; then
            echo "    [DRY-RUN] Would kill PID $target_pid"
        else
            kill "$target_pid" 2>/dev/null || true
        fi
    fi
}

# Color helpers (fallback to no-color if not a terminal)
if [ -t 1 ]; then
    BOLD='\033[1m'
    DIM='\033[2m'
    RED='\033[31m'
    GREEN='\033[32m'
    YELLOW='\033[33m'
    CYAN='\033[36m'
    RESET='\033[0m'
else
    BOLD='' DIM='' RED='' GREEN='' YELLOW='' CYAN='' RESET=''
fi

_header() { printf "\n${BOLD}${CYAN}=== %s ===${RESET}\n\n" "$1"; }
_warn()   { printf "${YELLOW}  ⚠ %s${RESET}\n" "$1"; }
_ok()     { printf "${GREEN}  ✓ %s${RESET}\n" "$1"; }
_info()   { printf "${DIM}  %s${RESET}\n" "$1"; }

# ─── cmd_ram: resource visualization ─────────────────────────────────────────
cmd_ram() {
    _header "Claude Code RAM Usage"

    # Sessions
    printf "${BOLD}  %-7s %8s %6s %s${RESET}\n" "PID" "RSS(MB)" "CPU%" "ELAPSED"
    printf "  %-7s %8s %6s %s\n" "-------" "--------" "------" "--------------"

    local session_count=0 session_kb=0
    while IFS= read -r pid; do
        [ -z "$pid" ] && continue
        local info
        info=$(ps -p "$pid" -o rss=,%cpu=,etime= 2>/dev/null)
        [ -z "$info" ] && continue
        local rss cpu etime
        rss=$(echo "$info" | awk '{print $1}')
        cpu=$(echo "$info" | awk '{print $2}')
        etime=$(echo "$info" | awk '{print $3}')
        printf "  %-7s %7d %6s %s\n" "$pid" "$((rss/1024))" "${cpu}%" "$etime"
        session_count=$((session_count + 1))
        session_kb=$((session_kb + rss))
    done < <(_get_session_pids)

    echo ""
    _info "Sessions: $session_count total, $((session_kb/1024)) MB"

    [ "$session_count" -ge 3 ] && _warn "$session_count sessions open! Consider closing idle ones."

    # Subagents
    echo ""
    printf "${BOLD}  Subagents${RESET}\n"
    ps aux 2>/dev/null | grep "[c]laude.*stream-json" | awk '{sum+=$6; cpu+=$3; count++} END {printf "  %d subagents, %.0f MB, %.1f%% CPU\n", count, sum/1024, cpu}'

    # MCP Servers
    printf "${BOLD}  MCP Servers${RESET}\n"
    ps aux 2>/dev/null | grep -E "[n]pm exec @upstash|[n]pm exec mcp-|[n]ode.*mcp-server|[n]px.*mcp-server|[n]ode.*context7|[c]hroma-mcp|[n]ode.*sequential-thinking|[w]orker-service|[n]ode.*claude-mem|[u]v.*chroma-mcp|[p]ython.*chroma-mcp|[b]un.*worker-service|[n]pm exec @supabase" | awk '{sum+=$6; cpu+=$3; count++} END {printf "  %d processes, %.0f MB, %.1f%% CPU\n", count, sum/1024, cpu}'

    # Orphans (PPID=1)
    printf "${BOLD}  Orphans (PPID=1)${RESET}\n"
    ps -eo pid,ppid,rss,%cpu,command 2>/dev/null | awk '$2 == 1' | grep -E "[c]laude.*stream-json|[n]ode.*mcp-server|[n]px.*mcp-server|[c]hroma-mcp|[w]orker-service\.cjs|[n]ode.*claude-mem" | awk '{sum+=$3; cpu+=$4; count++} END {printf "  %d orphans, %.0f MB, %.1f%% CPU\n", count, sum/1024, cpu}'

    # Total
    echo ""
    printf "${BOLD}  Total${RESET}\n"
    ps aux 2>/dev/null | grep -iE "[c]laude|[n]pm exec @supabase|[n]pm exec @upstash|[n]pm exec mcp-|[n]ode.*mcp-server|[n]px.*mcp-server|[n]ode.*context7|[c]hroma-mcp|[w]orker-service|[n]ode.*sequential-thinking|[n]ode.*claude-mem|[u]v.*chroma-mcp|[p]ython.*chroma-mcp|[b]un.*worker-service" | awk '{sum+=$6; cpu+=$3} END {printf "  %.0f MB (%.1f GB), %.1f%% CPU\n", sum/1024, sum/1024/1024, cpu}'
}

# ─── cmd_sessions: list active sessions ──────────────────────────────────────
cmd_sessions() {
    _header "Claude Code Active Sessions"

    printf "  ${BOLD}%-7s %8s %6s %-14s %-8s %s${RESET}\n" "PID" "TREE_MB" "CPU%" "ELAPSED" "STATUS" "CHILDREN"
    printf "  %-7s %8s %6s %-14s %-8s %s\n" "-------" "--------" "------" "--------------" "--------" "--------"

    local session_pids=()
    while IFS= read -r line; do
        session_pids+=("$line")
    done < <(_get_session_pids)

    local session_count=0 idle_count=0 total_mb=0

    if [ ${#session_pids[@]} -eq 0 ]; then
        _ok "No Claude Code sessions running."
        return 0
    fi

    for pid in "${session_pids[@]}"; do
        local info
        info=$(ps -p "$pid" -o rss=,%cpu=,etime= 2>/dev/null)
        [ -z "$info" ] && continue

        local cpu etime
        cpu=$(echo "$info" | awk '{print $2}')
        etime=$(echo "$info" | awk '{print $3}')
        local tree_mb
        tree_mb=$(_tree_rss "$pid")

        local cpu_int
        cpu_int=$(echo "$cpu" | awk '{printf "%d", $1}')
        local status="ACTIVE"
        if [ "$cpu_int" -lt 1 ]; then
            status="${YELLOW}[IDLE]${RESET}"
            idle_count=$((idle_count + 1))
        fi

        # Count descendants
        local child_count=0
        while IFS= read -r cpid; do
            [ -z "$cpid" ] && continue
            child_count=$((child_count + 1))
            while IFS= read -r gcpid; do
                [ -z "$gcpid" ] && continue
                child_count=$((child_count + 1))
            done < <(pgrep -P "$cpid" 2>/dev/null)
        done < <(pgrep -P "$pid" 2>/dev/null)

        printf "  %-7s %7s %6s %-14s %-8b %s (%s MB tree)\n" \
            "$pid" "$tree_mb" "${cpu}%" "$etime" "$status" "$child_count" "$tree_mb"

        session_count=$((session_count + 1))
        total_mb=$((total_mb + tree_mb))
    done

    echo ""
    _info "Sessions: $session_count total, $idle_count idle"
    _info "Total RAM (with children): ${total_mb} MB ($(echo "$total_mb" | awk '{printf "%.1f", $1/1024}') GB)"

    if [ "$idle_count" -gt 0 ] && [ "$session_count" -gt 0 ]; then
        local idle_mb=$((total_mb * idle_count / session_count))
        echo ""
        _warn "Close idle sessions to free ~${idle_mb} MB"
    fi

    [ "$session_count" -ge 4 ] && _warn "$session_count sessions is excessive (each = 400-900 MB)"
    return 0
}

# ─── cmd_clean: clean orphan processes ───────────────────────────────────────
cmd_clean() {
    local dry_run=false
    [ "${1:-}" = "--dry-run" ] && dry_run=true

    _header "Claude Code Orphan Cleanup"
    $dry_run && _info "Mode: DRY-RUN (no processes will be killed)"

    # Phase 1: PGID-based cleanup
    local pgid_kills=0
    local orphan_pgids
    orphan_pgids=$(ps -eo pid,ppid,pgid 2>/dev/null | awk '$1 == $3 && $2 == 1 {print $3}' | sort -u)

    for pgid in $orphan_pgids; do
        local leader_cmd
        leader_cmd=$(ps -o command= -p "$pgid" 2>/dev/null || true)
        [ -z "$leader_cmd" ] && continue
        if ! echo "$leader_cmd" | grep -qE "claude.*stream-json|claude.*--session-id"; then
            continue
        fi

        local match_count
        match_count=$(ps -eo pgid,command 2>/dev/null | awk -v pgid="$pgid" '$1 == pgid' | grep -cE "claude|mcp|chroma|worker-service" 2>/dev/null || echo 0)

        if [ "$match_count" -gt 0 ]; then
            local group_size
            group_size=$(ps -eo pid,pgid 2>/dev/null | awk -v pgid="$pgid" '$2 == pgid' | wc -l | tr -d ' ')

            if $dry_run; then
                echo "  [DRY-RUN] Would kill orphan PGID=$pgid ($group_size processes)"
            else
                kill -- -"$pgid" 2>/dev/null || true
                echo "  Killed orphan PGID=$pgid ($group_size processes)"
            fi
            pgid_kills=$((pgid_kills + group_size))
        fi
    done

    # Phase 2: Pattern-based fallback (only orphans with PPID=1)
    local orphan_count
    orphan_count=$(ps -eo ppid,command 2>/dev/null | awk '$1 == 1' | { grep -E "[c]laude.*stream-json" || true; } | wc -l | tr -d ' ')
    local mcp_count
    mcp_count=$(ps -eo ppid,command 2>/dev/null | awk '$1 == 1' | { grep -E "[n]pm exec @upstash|[n]pm exec mcp-|[n]px.*mcp-server|[n]ode.*sequential-thinking|[b]un.*worker-service|[w]orker-service\.cjs" || true; } | wc -l | tr -d ' ')

    if [ "$pgid_kills" -eq 0 ] && [ "$orphan_count" -eq 0 ] && [ "$mcp_count" -eq 0 ]; then
        _ok "No orphan processes found."
        return 0
    fi

    [ "$pgid_kills" -gt 0 ] && _info "PGID-based: killed $pgid_kills processes"

    if [ "$orphan_count" -gt 0 ] || [ "$mcp_count" -gt 0 ]; then
        _info "Pattern fallback: $orphan_count subagents, $mcp_count MCP processes"

        if $dry_run; then
            _info "[DRY-RUN] Would clean $orphan_count subagents + $mcp_count MCP stragglers"
        else
            # Only kill orphans: processes with PPID=1 or detached TTY (??)
            # Subagents with PPID=1 (orphaned)
            ps -eo pid,ppid,command 2>/dev/null | awk '$2 == 1' | grep -E "[c]laude.*stream-json" | awk '{print $1}' | xargs kill 2>/dev/null || true
            # MCP with PPID=1 or detached
            ps -eo pid,ppid,command 2>/dev/null | awk '$2 == 1' | grep -E "[n]pm exec @upstash|[n]pm exec mcp-|[n]px.*mcp-server|[n]ode.*sequential-thinking" | awk '{print $1}' | xargs kill 2>/dev/null || true
            ps -eo pid,ppid,command 2>/dev/null | awk '$2 == 1' | grep -E "[w]orker-service\.cjs|[b]un.*worker-service" | grep -vE "$MCP_WHITELIST" | awk '{print $1}' | xargs kill 2>/dev/null || true
        fi
    fi

    if ! $dry_run; then
        sleep 1
        local remaining
        remaining=$(ps aux 2>/dev/null | { grep -E "[c]laude.*stream-json|[n]pm exec @upstash|[n]pm exec mcp-|[n]px.*mcp-server" || true; } | wc -l | tr -d ' ')
        _ok "Cleanup done. Remaining: $remaining processes"
    fi
    return 0
}

# ─── cmd_auto: automatic session guard ───────────────────────────────────────
cmd_auto() {
    local dry_run=false
    [ "${1:-}" = "--dry-run" ] && dry_run=true

    _header "Claude Guard"
    _info "Config: max_sessions=$CC_MAX_SESSIONS, idle_threshold=${CC_IDLE_THRESHOLD}%, max_rss=${CC_MAX_RSS_MB} MB"
    $dry_run && _info "Mode: DRY-RUN"
    echo ""

    # Validate CC_MAX_RSS_MB
    if ! echo "$CC_MAX_RSS_MB" | grep -qE '^[0-9]+$'; then
        _warn "CC_MAX_RSS_MB='$CC_MAX_RSS_MB' is not numeric, using default 4096"
        CC_MAX_RSS_MB=4096
    fi

    # Gather sessions
    local session_pids=()
    while IFS= read -r line; do
        session_pids+=("$line")
    done < <(_get_session_pids)

    local session_count=${#session_pids[@]}
    if [ "$session_count" -eq 0 ]; then
        _ok "No Claude Code sessions running."
        return 0
    fi

    # Classify sessions
    local bloated_pids=() bloated_rss=()
    local idle_pids=() idle_etimes=()
    local live_count=0

    printf "  ${BOLD}%-7s %8s %6s %-14s %s${RESET}\n" "PID" "TREE_MB" "CPU%" "ELAPSED" "STATUS"
    printf "  %-7s %8s %6s %-14s %s\n" "-------" "--------" "------" "--------------" "--------"

    for pid in "${session_pids[@]}"; do
        local info
        info=$(ps -p "$pid" -o rss=,%cpu=,etime= 2>/dev/null)
        [ -z "$info" ] && continue

        local cpu etime tree_mb cpu_int status
        cpu=$(echo "$info" | awk '{print $2}')
        etime=$(echo "$info" | awk '{print $3}')
        tree_mb=$(_tree_rss "$pid")
        cpu_int=$(echo "$cpu" | awk '{printf "%d", $1}')

        status="LIVE"
        if [ "$tree_mb" -ge "$CC_MAX_RSS_MB" ]; then
            status="${RED}[BLOATED]${RESET}"
            bloated_pids+=("$pid")
            bloated_rss+=("$tree_mb")
        elif [ "$cpu_int" -lt "$CC_IDLE_THRESHOLD" ]; then
            status="${YELLOW}[IDLE]${RESET}"
            idle_pids+=("$pid")
            idle_etimes+=("$etime")
        else
            live_count=$((live_count + 1))
        fi

        printf "  %-7s %7s %6s %-14s %b\n" "$pid" "$tree_mb" "${cpu}%" "$etime" "$status"
    done

    echo ""
    _info "Sessions: $session_count total, ${#bloated_pids[@]} bloated, ${#idle_pids[@]} idle, $live_count live"

    # Phase 1: Kill bloated
    local killed=0 freed_mb=0

    if [ ${#bloated_pids[@]} -gt 0 ]; then
        echo ""
        printf "  ${BOLD}${RED}Killing bloated sessions (tree RSS > ${CC_MAX_RSS_MB} MB)${RESET}\n"
        for i in "${!bloated_pids[@]}"; do
            local bpid=${bloated_pids[$i]}
            local brss=${bloated_rss[$i]}
            if $dry_run; then
                echo "  [DRY-RUN] Would kill PID $bpid (${brss} MB > ${CC_MAX_RSS_MB} MB threshold)"
            else
                _pgid_kill "$bpid" "false"
                echo "  Killed PID $bpid (${brss} MB)"
                killed=$((killed + 1))
                freed_mb=$((freed_mb + brss))
                # macOS notification
                osascript -e "display notification \"Killed session PID $bpid — ${brss} MB\" with title \"Claude Guard\" subtitle \"Bloated session reaped\"" 2>/dev/null &
            fi
        done
    fi

    # Phase 2: Kill idle if over max_sessions
    local remaining=$((session_count - killed))
    if [ "$remaining" -gt "$CC_MAX_SESSIONS" ] && [ ${#idle_pids[@]} -gt 0 ]; then
        local to_kill=$((remaining - CC_MAX_SESSIONS))
        [ "$to_kill" -gt "${#idle_pids[@]}" ] && to_kill=${#idle_pids[@]}

        echo ""
        printf "  ${BOLD}${YELLOW}Killing $to_kill idle session(s) to reach limit of $CC_MAX_SESSIONS${RESET}\n"
        for i in $(seq 0 $((to_kill - 1))); do
            local ipid=${idle_pids[$i]}
            local ietime=${idle_etimes[$i]}
            local irss
            irss=$(_tree_rss "$ipid")
            if $dry_run; then
                echo "  [DRY-RUN] Would kill PID $ipid (idle ${ietime}, ${irss} MB)"
            else
                _pgid_kill "$ipid" "false"
                echo "  Killed PID $ipid (idle ${ietime}, ${irss} MB)"
                killed=$((killed + 1))
                freed_mb=$((freed_mb + irss))
            fi
        done
    fi

    # Summary
    echo ""
    if [ "$killed" -gt 0 ]; then
        _ok "Reaped $killed session(s), freed ~${freed_mb} MB"
        if ! $dry_run; then
            osascript -e "display notification \"Reaped $killed session(s), freed ~${freed_mb} MB\" with title \"Claude Guard\" subtitle \"Cleanup complete\"" 2>/dev/null &
        fi
    elif $dry_run && [ ${#bloated_pids[@]} -eq 0 ] && [ "$remaining" -le "$CC_MAX_SESSIONS" ]; then
        _ok "All clear — no sessions to reap."
    elif ! $dry_run; then
        _ok "All clear — no sessions to reap."
    fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────
cmd_help() {
    cat <<EOF
claude-guard v${VERSION} — Claude Code process resource manager

Usage: guard.sh <command> [options]

Commands:
  ram         Show RAM/CPU usage by category (sessions, subagents, MCP, orphans)
  clean       Kill orphan processes (PGID + pattern fallback)
  sessions    List active sessions with idle detection and tree RAM
  auto        Automatic guard: kill bloated + evict idle sessions

Options:
  --dry-run   Preview actions without killing (clean, auto)
  --help      Show this help

Environment:
  CC_MAX_SESSIONS     Max allowed sessions before idle eviction (default: 3)
  CC_IDLE_THRESHOLD   CPU% below which session is idle (default: 1)
  CC_MAX_RSS_MB       Tree RSS threshold in MB for bloated kill (default: 4096)

Examples:
  guard.sh ram                 # show resource usage
  guard.sh clean --dry-run     # preview orphan cleanup
  guard.sh sessions            # list sessions
  guard.sh auto --dry-run      # preview auto-guard
EOF
}

case "${1:-help}" in
    ram)      cmd_ram ;;
    clean)    shift; cmd_clean "$@" ;;
    sessions) cmd_sessions ;;
    auto)     shift; cmd_auto "$@" ;;
    --help|help|-h) cmd_help ;;
    --version|-v) echo "claude-guard v${VERSION}" ;;
    *) echo "Unknown command: $1"; cmd_help; exit 1 ;;
esac
