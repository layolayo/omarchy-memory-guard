#!/bin/bash
# OMARAM Guard - AI Process Memory Diagnosis
# Pauses an offending process via SIGSTOP and launches an Omarchy AI agent to diagnose the memory bloat.

set -uo pipefail

pid=${1:?usage: omaram-diagnose <pid>}

if [[ ! $pid =~ ^[0-9]+$ ]]; then
  echo "Invalid PID: $pid" >&2
  exit 1
fi

# Ensure process exists and belongs to current user
if [[ ! -d "/proc/$pid" ]]; then
  echo "Process $pid does not exist." >&2
  exit 1
fi

owner=$(stat -c '%u' "/proc/$pid" 2>/dev/null || true)
if [[ "$owner" != "$UID" ]]; then
  echo "Refusing to inspect process $pid (not owned by current user)." >&2
  exit 1
fi

# 1. Freeze process immediately to halt memory allocation and preserve state
kill -STOP "$pid" 2>/dev/null || true

# 2. Gather process facts
comm=$(cat "/proc/$pid/comm" 2>/dev/null || echo "unknown")
exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null || echo "unknown")
cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || echo "$comm")
cwd=$(readlink -f "/proc/$pid/cwd" 2>/dev/null || echo "unknown")

rss_kb=$(awk '/VmRSS:/ {print $2}' "/proc/$pid/status" 2>/dev/null || echo "0")
rss_mb=$((rss_kb / 1024))
swap_kb=$(awk '/VmSwap:/ {print $2}' "/proc/$pid/status" 2>/dev/null || echo "0")
swap_mb=$((swap_kb / 1024))
threads=$(awk '/Threads:/ {print $2}' "/proc/$pid/status" 2>/dev/null || echo "1")

pss_kb=$(awk '/^Pss:/ {print $2}' "/proc/$pid/smaps_rollup" 2>/dev/null || echo "0")
pss_mb=$((pss_kb / 1024))

total_kb=$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo "1")
pmem=$((rss_kb * 100 / total_kb))

# 3. Construct structured prompt for the Omarchy coding agent
prompt=$(cat <<PROMPT
A process has been paused with SIGSTOP via OMARAM Guard because it is consuming excessive memory ($rss_mb MB, ~$pmem% of total system RAM).

Investigate why this process is consuming so much memory, check for memory leaks, runaway loops, or uncollected buffers, and advise on whether to resume (SIGCONT) or terminate (SIGKILL).

Target Process:
  PID:         $pid
  Process:     $comm
  Binary:      $exe
  Command:     $cmdline
  Working Dir: $cwd
  Memory RSS:  $rss_mb MB (~$pmem% RAM)
  Memory PSS:  $pss_mb MB
  Swap Used:   $swap_mb MB
  Threads:     $threads
  State:       PAUSED (SIGSTOP)

Investigation instructions:
1. Examine /proc/$pid/status and /proc/$pid/smaps_rollup to analyze memory allocations (anonymous vs file-backed memory, dirty pages).
2. Check open file descriptors in /proc/$pid/fd/ and network sockets if relevant.
3. Review recent systemd journal logs: journalctl _PID=$pid --since "15 minutes ago" --no-pager.
4. If this is a script, runtime, or browser process, identify which file, tab, or task is causing the bloat.
5. Provide a clear summary:
   - What the process is currently doing
   - Why memory is elevated
   - Safe next action: Resume (kill -CONT $pid) or Terminate (kill -9 $pid)
PROMPT
)

# 4. Launch the default Omarchy agent in an interactive floating TUI
exec omarchy-agent --prompt "$prompt"
