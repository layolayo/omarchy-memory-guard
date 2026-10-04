#!/bin/bash
# OMARAM Guard - AI Process Memory Diagnosis
# Pauses an offending process via SIGSTOP and launches an Omarchy AI agent to diagnose the memory bloat.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pid=""
diff_seconds=""
snapshot_file=""
report_only=0
inline=0

# Parse options & PID
while [[ $# -gt 0 ]]; do
  case "$1" in
    --diff|-d)
      if [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]]; then
        diff_seconds="$2"
        shift 2
      else
        diff_seconds=30
        shift
      fi
      ;;
    --snapshot-file|-s)
      snapshot_file="${2:?--snapshot-file requires a file path}"
      shift 2
      ;;
    --report-only|-r)
      report_only=1
      shift
      ;;
    --inline|-i)
      inline=1
      shift
      ;;
    *)
      if [[ -z "$pid" ]]; then
        pid="$1"
        shift
      else
        echo "Unexpected argument: $1" >&2
        exit 1
      fi
      ;;
  esac
done

if [[ -z "$pid" ]]; then
  echo "usage: omaram-diagnose <pid> [--diff [seconds]] [--snapshot-file <path>] [--report-only]" >&2
  exit 1
fi

# Validate PID: must be positive numeric integer > 1 and not current/parent process
if [[ ! $pid =~ ^[0-9]+$ ]] || (( pid <= 1 )) || (( pid == $$ )) || (( pid == PPID )); then
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

# Optional: Run Differential Profiling if requested
snapshot_content=""
if [[ -n "$diff_seconds" ]]; then
  diff_tmp=$(mktemp -t omaram-diff-XXXXXX)
  chmod 600 "$diff_tmp"
  trap 'rm -f "$diff_tmp"' EXIT
  if [[ "$report_only" -eq 1 || ! -t 1 ]]; then
    "$SCRIPT_DIR/omaram-diff-profile.sh" "$pid" --duration "$diff_seconds" --output "$diff_tmp" --quiet
  else
    "$SCRIPT_DIR/omaram-diff-profile.sh" "$pid" --duration "$diff_seconds" --output "$diff_tmp" --progress
  fi
  snapshot_content=$(cat "$diff_tmp" 2>/dev/null || true)
  rm -f "$diff_tmp"
elif [[ -n "$snapshot_file" && -f "$snapshot_file" ]]; then
  snapshot_content=$(cat "$snapshot_file" 2>/dev/null || true)
  rm -f "$snapshot_file" # Ephemeral file cleanup
fi

# 1. Freeze process immediately to halt memory allocation and preserve state
kill -STOP "$pid" 2>/dev/null || true

if [[ "$report_only" -eq 0 ]]; then
  AI_DIAG_REGISTRY="${XDG_RUNTIME_DIR:-/run/user/$UID}/omaram/ai_diagnose.registry"
  mkdir -p "$(dirname "$AI_DIAG_REGISTRY")"
  if ! grep -qw "$pid" "$AI_DIAG_REGISTRY" 2>/dev/null; then
    echo "$pid" >> "$AI_DIAG_REGISTRY"
  fi

  cleanup_ai_diag() {
    if [[ -f "$AI_DIAG_REGISTRY" ]]; then
      sed -i "/^${pid}$/d" "$AI_DIAG_REGISTRY" 2>/dev/null || true
    fi
  }
  trap cleanup_ai_diag EXIT INT TERM
fi

# 2. Gather process facts
comm=$(cat "/proc/$pid/comm" 2>/dev/null || echo "unknown")
# Strip directory components if prctl set a custom path-like name, matching omarchy-crash-watch
comm=${comm##*/}
[[ -n $comm && $comm != "-" && $comm != "." && $comm != ".." ]] || comm="unknown"
comm=$(printf '%s' "$comm" | tr -cd '[:print:]')

exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null || echo "unknown")
exe=$(printf '%s' "$exe" | tr -cd '[:print:]')

cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || echo "$comm")

# Sanitize and redact inline credentials (passwords, tokens, API keys, basic auth URLs)
clean_cmdline=$(printf '%s' "$cmdline" | sed -E \
  -e 's|://([^/:]+):([^/@]+)@|://\1:[REDACTED]@|g' \
  -e 's/((key|token|secret|password|passwd|auth|bearer|credential|api_key|apikey)=)[^ &"'\''\t\n]+/\1[REDACTED]/gI' \
  -e 's/(--(token|key|secret|password|api-key|auth-token|private-key|access-token|client-secret)[= ])[^ "'\''\t\n]+/\1[REDACTED]/gI' \
  -e 's/(-[pPuU])[ =][^ "'\''\t\n]+/\1 [REDACTED]/g' \
  -e 's/(Bearer )[a-zA-Z0-9_\-\.]+/Bearer [REDACTED]/gI' \
  -e 's/(ghp|gho|ghu|ghs|ghr)_[a-zA-Z0-9]{36,}/[REDACTED_GITHUB_TOKEN]/g' \
  -e 's/github_pat_[a-zA-Z0-9_]{50,}/[REDACTED_GITHUB_PAT]/g' \
  -e 's/glpat-[a-zA-Z0-9\-]{20,}/[REDACTED_GITLAB_TOKEN]/g' \
  -e 's/xox[baprs]-[a-zA-Z0-9\-]+/[REDACTED_SLACK_TOKEN]/g' \
  -e 's/sk-[a-zA-Z0-9_\-]{20,}/[REDACTED_API_KEY]/g')

# Sanitize strings to strip binary control characters
clean_cmdline=$(printf '%s' "$clean_cmdline" | tr -cd '[:print:]\t\n')

cwd=$(readlink -f "/proc/$pid/cwd" 2>/dev/null || echo "unknown")
cwd=$(printf '%s' "$cwd" | tr -cd '[:print:]')

ppid=$(awk '/PPid:/ {print $2}' "/proc/$pid/status" 2>/dev/null || echo "1")
parent_comm=$(cat "/proc/$ppid/comm" 2>/dev/null || echo "unknown")
parent_comm=${parent_comm##*/}
[[ -n $parent_comm && $parent_comm != "-" && $parent_comm != "." && $parent_comm != ".." ]] || parent_comm="unknown"
parent_comm=$(printf '%s' "$parent_comm" | tr -cd '[:print:]')

rss_kb=$(awk '/VmRSS:/ {print $2}' "/proc/$pid/status" 2>/dev/null || echo "0")
rss_mb=$((rss_kb / 1024))
swap_kb=$(awk '/VmSwap:/ {print $2}' "/proc/$pid/status" 2>/dev/null || echo "0")
swap_mb=$((swap_kb / 1024))
threads=$(awk '/Threads:/ {print $2}' "/proc/$pid/status" 2>/dev/null || echo "1")

pss_kb=$(awk '/^Pss:/ {print $2}' "/proc/$pid/smaps_rollup" 2>/dev/null || echo "0")
pss_mb=$((pss_kb / 1024))

total_kb=$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo "1")
pmem=$((rss_kb * 100 / (total_kb > 0 ? total_kb : 1)))

docs="$SCRIPT_DIR/../docs/INVESTIGATION.md"
if [[ ! -f "$docs" ]]; then
  docs="$HOME/.config/omarchy/plugins/io.github.layolayo.memory-guard/docs/INVESTIGATION.md"
fi

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
PROMPT
)

if [[ -n "$snapshot_content" ]]; then
  prompt+=$(cat <<DIFF_BLOCK


$snapshot_content
DIFF_BLOCK
)
fi

prompt+=$(cat <<PROMPT_TAIL


Privacy Invariants:
- NEVER read /proc/$pid/environ (contains sensitive environment tokens and secrets).
- NEVER dump /proc/$pid/mem (contains raw memory bytes).
- Inspect /proc/$pid/fd/ only to identify file paths and locks; NEVER read the file contents of private user documents.
- Ephemeral file hygiene: If writing temporary diagnostic files or memory analysis dumps, write only to a fresh \`mktemp -t omaram-XXXXXX\` path and delete it with \`trap 'rm -f ...' EXIT\` before exiting. Never leave memory dump files in /tmp.
- Provenance signing: End your report with: \`> Diagnosed by <model name> via <agent harness>.\`

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
     [1] 💀 Terminate: Run \`kill -9 $pid\` to immediately reclaim all RAM.
     [2] 🔄 Clean Restart: Kill \$pid and re-launch the application fresh with its original command line and working directory (preserving sandbox boundaries; never execute confined or containerized applications on the unconfined host).
     [3] ▶️ Resume: Run \`kill -CONT $pid\` if memory consumption was legitimate or user needs to save open work.
     [4] 🎯 Targeted Reclaim: If this is a child renderer tab, worker, or sub-process, pinpoint the specific tab or task to close to preserve the main application.
   - Diagnostic discipline: Diagnosis reads; it does not destroy, unpause, or mutate without explicit confirmation. Present findings first and wait for the user to confirm before running a destructive signal or restart. Leave the system as you found it.
PROMPT_TAIL
)

# If report-only requested, print prompt and exit
if [[ "$report_only" -eq 1 ]]; then
  printf "%s\n" "$prompt"
  exit 0
fi

# Ensure any floating OMARAM window is snapped to tile so agent opens side-by-side
tile_if_floating() {
  if [ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
    return 0
  fi

  local clients_json omaram_addr
  clients_json=$(hyprctl clients -j 2>/dev/null || true)
  if [[ -n "$clients_json" ]]; then
    omaram_addr=$(echo "$clients_json" | jq -r '
      .[] | select(
        (.floating == true) and (
          (.class == "org.omarchy.terminal.omaram") or
          (.initialClass == "org.omarchy.terminal.omaram") or
          ((.title // "") | contains("OMARAM"))
        )
      ) | .address' 2>/dev/null | head -1 || true)

    if [[ -n "$omaram_addr" ]]; then
      hyprctl dispatch "hl.dsp.window.float({ window = '\''address:'\'' .. omaram_addr, action = '\''off'\'' })" >/dev/null 2>&1 || true
    fi
  fi

  hyprctl eval '
    for _, w in ipairs(hl.get_windows()) do
      local match = (w.class == "org.omarchy.terminal.omaram")
        or (w.initial_class == "org.omarchy.terminal.omaram")
        or (w.title and string.find(w.title, "OMARAM"))
      if match and w.floating then
        hl.dispatch(hl.dsp.window.float({ window = w, action = "off" }))
      end
    end
  ' >/dev/null 2>&1 || true
}

tile_if_floating

# 4. Launch the default Omarchy agent in an interactive floating TUI
if [[ "$inline" -eq 1 ]]; then
  omarchy-agent --inline --prompt "$prompt"
else
  omarchy-agent --prompt "$prompt"
fi
