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
# Sanitize and redact common inline credentials (passwords, tokens, API keys)
clean_cmdline=$(printf '%s' "$cmdline" | sed -E \
  -e 's/((key|token|secret|password|passwd|auth|bearer)=)[^ &]+/\1[REDACTED]/gI' \
  -e 's/(--(token|key|secret|password|api-key|auth-token|private-key)[= ])[^ ]+/\1[REDACTED]/gI' \
  -e 's/(-[pP])[ =][^ ]+/\1 [REDACTED]/g' \
  -e 's/(Bearer )[a-zA-Z0-9_\-\.]+/Bearer [REDACTED]/gI')

cwd=$(readlink -f "/proc/$pid/cwd" 2>/dev/null || echo "unknown")

ppid=$(awk '/PPid:/ {print $2}' "/proc/$pid/status" 2>/dev/null || echo "1")
parent_comm=$(cat "/proc/$ppid/comm" 2>/dev/null || echo "unknown")

rss_kb=$(awk '/VmRSS:/ {print $2}' "/proc/$pid/status" 2>/dev/null || echo "0")
rss_mb=$((rss_kb / 1024))
swap_kb=$(awk '/VmSwap:/ {print $2}' "/proc/$pid/status" 2>/dev/null || echo "0")
swap_mb=$((swap_kb / 1024))
threads=$(awk '/Threads:/ {print $2}' "/proc/$pid/status" 2>/dev/null || echo "1")

pss_kb=$(awk '/^Pss:/ {print $2}' "/proc/$pid/smaps_rollup" 2>/dev/null || echo "0")
pss_mb=$((pss_kb / 1024))

total_kb=$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo "1")
pmem=$((rss_kb * 100 / total_kb))

docs="$HOME/.config/omarchy/plugins/io.github.layolayo.memory-guard/docs/INVESTIGATION.md"

# 3. Construct structured prompt for the Omarchy coding agent
prompt=$(cat <<PROMPT
A process has been paused with SIGSTOP via OMARAM Guard because it is consuming excessive RAM ($rss_mb MB, ~$pmem% of total system memory).

The process is currently frozen in RAM as a precursor to an Out-Of-Memory (OOM) kill or system freeze. Your goal is to investigate why this process is consuming so much memory, check for memory leaks or runaway loops, assess data loss risk, and provide an evidence-based recommendation on whether to resume (SIGCONT) or terminate (SIGKILL).

Target Process:
  PID:         $pid
  Process:     $comm
  Parent:      $parent_comm (PID $ppid)
  Binary:      $exe
  Command:     $clean_cmdline
  Working Dir: $cwd
  Memory RSS:  $rss_mb MB (~$pmem% of system RAM)
  Memory PSS:  $pss_mb MB
  Swap Used:   $swap_mb MB
  Threads:     $threads
  State:       PAUSED (SIGSTOP)

Privacy Invariants:
- NEVER read /proc/$pid/environ (contains sensitive environment tokens and secrets).
- NEVER dump /proc/$pid/mem (contains raw memory bytes).
- Inspect /proc/$pid/fd/ only to identify file paths and locks; NEVER read the file contents of private user documents.

Investigation instructions:
Follow the Omarchy memory investigation guide:
  $docs

Key objectives:
1. Establish evidence: Read /proc/$pid/status and /proc/$pid/smaps_rollup to analyze whether this is private dirty heap (leak/active data) vs shared/file-backed cache.
2. In-flight work & data safety: Inspect open file descriptors in /proc/$pid/fd/ to determine if unsaved files, database writes, or active sockets would be damaged by termination.
3. Check journalctl _PID=$pid --since "15 minutes ago" --no-pager for error bursts or GC failure cycles.
4. Report & Next-Steps Action Menu:
   - Summary of what the process was actively working on
   - The verified mechanism causing the memory bloat (distinguishing proven facts from inferences)
   - Data loss risk assessment (identifying unsaved files or database locks)
   - Conclude by presenting a clear, numbered Action Menu and offer to execute the user's choice:
     [1] 💀 Terminate: Run `kill -9 $pid` to immediately reclaim all RAM.
     [2] 🔄 Clean Restart: Kill `$pid` and re-launch the application fresh with its original command line and working directory.
     [3] ▶️ Resume: Run `kill -CONT $pid` if memory consumption was legitimate or user needs to save open work.
     [4] 🎯 Targeted Reclaim: If this is a child renderer tab, worker, or sub-process, pinpoint the specific tab or task to close to preserve the main application.
   - Diagnostic discipline: Diagnosis reads; always present the findings first and wait for the user to confirm before running a destructive signal or restart.
PROMPT
)

# 4. Launch the default Omarchy agent in an interactive floating TUI
exec omarchy-agent --prompt "$prompt"
