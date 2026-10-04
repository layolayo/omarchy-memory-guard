#!/bin/bash
# OMARAM Guard - AI Differential Memory Snapshot Profiler
# Samples memory allocations, file descriptors, sockets, and execution metrics
# across a time window (T0 -> T1) to isolate runaway leaks, socket exhaustion,
# and thread churn.
#
# Usage:
#   omaram-diff-profile.sh <pid> [--duration <secs>] [--output <file>] [--progress] [--quiet]

set -euo pipefail

PID=""
DURATION=30
OUTPUT_FILE=""
SHOW_PROGRESS=0
QUIET=0
RESUME_IF_PAUSED=1

# 1. Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --duration|-d)
            DURATION="${2:-30}"
            shift 2
            ;;
        --output|-o)
            OUTPUT_FILE="${2:-}"
            shift 2
            ;;
        --progress|-p)
            SHOW_PROGRESS=1
            shift
            ;;
        --quiet|-q)
            QUIET=1
            shift
            ;;
        --no-resume)
            RESUME_IF_PAUSED=0
            shift
            ;;
        *)
            if [[ -z "$PID" ]]; then
                PID="$1"
                shift
            else
                echo "Unexpected argument: $1" >&2
                exit 1
            fi
            ;;
    esac
done

if [[ -z "$PID" ]]; then
    echo "Usage: omaram-diff-profile.sh <pid> [--duration <secs>] [--output <file>] [--progress] [--quiet]" >&2
    exit 1
fi

# 2. Validate PID: positive numeric integer > 1, not current/parent process
if [[ ! "$PID" =~ ^[0-9]+$ ]] || (( PID <= 1 )) || (( PID == $$ )) || (( PID == PPID )); then
    echo "Invalid PID: $PID" >&2
    exit 1
fi

# Ensure process exists and belongs to current user
if [[ ! -d "/proc/$PID" ]]; then
    echo "Process $PID does not exist." >&2
    exit 1
fi

OWNER=$(stat -c '%u' "/proc/$PID" 2>/dev/null || true)
if [[ "$OWNER" != "$UID" ]]; then
    echo "Refusing to profile process $PID (not owned by current user)." >&2
    exit 1
fi

# Validate duration: must be integer between 1 and 300
if [[ ! "$DURATION" =~ ^[0-9]+$ ]] || (( DURATION < 1 || DURATION > 300 )); then
    echo "Invalid duration: $DURATION (must be 1-300 seconds)" >&2
    exit 1
fi

# Check process comm & sanitize basename
COMM=$(cat "/proc/$PID/comm" 2>/dev/null || echo "unknown")
COMM=${COMM##*/}
[[ -n "$COMM" && "$COMM" != "-" && "$COMM" != "." && "$COMM" != ".." ]] || COMM="unknown"
COMM=$(printf '%s' "$COMM" | tr -cd '[:print:]')

INITIAL_STATE=$(awk '/^State:/ {print $2}' "/proc/$PID/status" 2>/dev/null || echo "S")
WAS_PAUSED=0
[[ "$INITIAL_STATE" =~ ^T ]] && WAS_PAUSED=1

# Clean-up and restore trap
cleanup() {
    local exit_code=$?
    if [[ "$WAS_PAUSED" -eq 1 && -d "/proc/$PID" ]]; then
        kill -STOP "$PID" 2>/dev/null || true
    fi
    exit "$exit_code"
}
trap cleanup EXIT
trap 'WAS_PAUSED=1; exit 130' INT TERM

# 3. Helper: Sample process facts
sample_metrics() {
    local target_pid="$1"
    local prefix="$2" # e.g. "T0" or "T1"

    if [[ ! -d "/proc/$target_pid" ]]; then
        return 1
    fi

    local status_file="/proc/$target_pid/status"
    local smaps_file="/proc/$target_pid/smaps_rollup"
    local stat_file="/proc/$target_pid/stat"

    local vm_rss=0 vm_data=0 vm_size=0 vm_swap=0 threads=1
    if [[ -f "$status_file" ]]; then
        vm_rss=$(awk '/^VmRSS:/ {print $2}' "$status_file" 2>/dev/null || echo 0)
        vm_data=$(awk '/^VmData:/ {print $2}' "$status_file" 2>/dev/null || echo 0)
        vm_size=$(awk '/^VmSize:/ {print $2}' "$status_file" 2>/dev/null || echo 0)
        vm_swap=$(awk '/^VmSwap:/ {print $2}' "$status_file" 2>/dev/null || echo 0)
        threads=$(awk '/^Threads:/ {print $2}' "$status_file" 2>/dev/null || echo 1)
    fi

    local pss=0 p_dirty=0 p_clean=0 s_dirty=0 s_clean=0 anon=0
    if [[ -f "$smaps_file" ]]; then
        pss=$(awk '/^Pss:/ {print $2}' "$smaps_file" 2>/dev/null || echo 0)
        p_dirty=$(awk '/^Private_Dirty:/ {print $2}' "$smaps_file" 2>/dev/null || echo 0)
        p_clean=$(awk '/^Private_Clean:/ {print $2}' "$smaps_file" 2>/dev/null || echo 0)
        s_dirty=$(awk '/^Shared_Dirty:/ {print $2}' "$smaps_file" 2>/dev/null || echo 0)
        s_clean=$(awk '/^Shared_Clean:/ {print $2}' "$smaps_file" 2>/dev/null || echo 0)
        anon=$(awk '/^Anonymous:/ {print $2}' "$smaps_file" 2>/dev/null || echo 0)
    fi

    local utime=0 stime=0
    if [[ -f "$stat_file" ]]; then
        utime=$(awk '{print $14}' "$stat_file" 2>/dev/null || echo 0)
        stime=$(awk '{print $15}' "$stat_file" 2>/dev/null || echo 0)
    fi

    local fd_count=0 sock_count=0 pipe_count=0 file_count=0
    local -a fd_targets=()
    if [[ -d "/proc/$target_pid/fd" ]]; then
        for fd_link in "/proc/$target_pid/fd/"*; do
            [[ -e "$fd_link" || -L "$fd_link" ]] || continue
            (( fd_count++ )) || true
            local target
            target=$(readlink "$fd_link" 2>/dev/null || true)
            [[ -z "$target" ]] && continue
            fd_targets+=("$target")
            if [[ "$target" =~ ^socket: ]]; then
                (( sock_count++ )) || true
            elif [[ "$target" =~ ^pipe: ]]; then
                (( pipe_count++ )) || true
            elif [[ "$target" =~ ^/ ]]; then
                (( file_count++ )) || true
            fi
        done
    fi

    local uss=$(( p_clean + p_dirty ))
    [[ "$uss" -eq 0 && "$vm_rss" -gt 0 ]] && uss="$vm_rss"

    eval "${prefix}_TIME=\$(date +%s)"
    eval "${prefix}_RSS=$vm_rss"
    eval "${prefix}_DATA=$vm_data"
    eval "${prefix}_SIZE=$vm_size"
    eval "${prefix}_SWAP=$vm_swap"
    eval "${prefix}_THREADS=$threads"
    eval "${prefix}_PSS=$pss"
    eval "${prefix}_USS=$uss"
    eval "${prefix}_ANON=$anon"
    eval "${prefix}_UTIME=$utime"
    eval "${prefix}_STIME=$stime"
    eval "${prefix}_FD_COUNT=$fd_count"
    eval "${prefix}_SOCK_COUNT=$sock_count"
    eval "${prefix}_PIPE_COUNT=$pipe_count"
    eval "${prefix}_FILE_COUNT=$file_count"
    eval "${prefix}_FD_TARGETS=(\"\${fd_targets[@]}\")"
}

# 4. Capture initial snapshot T0
sample_metrics "$PID" "T0" || {
    echo "Failed to capture initial metrics for PID $PID" >&2
    exit 1
}

# If process was paused and we want dynamic sampling, resume it temporarily
if [[ "$WAS_PAUSED" -eq 1 && "$RESUME_IF_PAUSED" -eq 1 ]]; then
    kill -CONT "$PID" 2>/dev/null || true
fi

# 5. Progressive sampling loop
if [[ "$SHOW_PROGRESS" -eq 1 || ( -t 1 && "$QUIET" -eq 0 ) ]]; then
    # Clear and render initial progress frame
    printf "\033[?25l" # Hide cursor
    trap 'printf "\033[?25h"; cleanup' EXIT

    BOX_W=58
    TITLE=" Differential Memory Snapshot Profiler: $COMM (PID $PID) "
    SUBTITLE=" Sampling dynamic allocation delta across ${DURATION}s "
    
    pad_title=$(( (BOX_W - ${#TITLE}) / 2 ))
    pad_sub=$(( (BOX_W - ${#SUBTITLE}) / 2 ))

    printf "\n"
    printf "  \033[1;36m┌%s┐\033[0m\n" "$(printf '─%.0s' $(seq 1 $BOX_W))"
    printf "  \033[1;36m│\033[1;37m%*s%s%*s\033[1;36m│\033[0m\n" "$pad_title" "" "$TITLE" "$(( BOX_W - ${#TITLE} - pad_title ))" ""
    printf "  \033[1;36m│\033[2;37m%*s%s%*s\033[1;36m│\033[0m\n" "$pad_sub" "" "$SUBTITLE" "$(( BOX_W - ${#SUBTITLE} - pad_sub ))" ""
    printf "  \033[1;36m└%s┘\033[0m\n" "$(printf '─%.0s' $(seq 1 $BOX_W))"
    printf "\n"

    # Print placeholder lines for dynamic in-place updates
    printf "   \033[2;37mInitializing sensor telemetry...\033[0m\n"
    printf "   \033[2;37mMemory: %d MB USS • Threads: %d • Sockets: %d\033[0m\n" "$(( T0_USS / 1024 ))" "$T0_THREADS" "$T0_SOCK_COUNT"
    printf "   \033[2;37mElapsed: 0s / %ds\033[0m\n" "$DURATION"
    printf "\n"
    printf "   \033[2;38;5;244mPress [Esc] to cancel profiling and return\033[0m\n"
fi

START_SEC=$(date +%s)
for (( elapsed = 1; elapsed <= DURATION; elapsed++ )); do
    # Check if process is still alive
    if [[ ! -d "/proc/$PID" ]]; then
        [[ "$SHOW_PROGRESS" -eq 1 || ( -t 1 && "$QUIET" -eq 0 ) ]] && printf "\033[?25h\n\033[1;31m❌ Process $PID terminated during profiling window.\033[0m\n"
        exit 1
    fi

    # Read keystroke for 1 second timeout (allows instant Esc cancel)
    if read -s -n 1 -t 1 key 2>/dev/null; then
        if [[ "$key" == $'\e' || "$key" == "q" || "$key" == "Q" ]]; then
            # Read remainder of escape sequence if any
            read -s -n 2 -t 0.05 _rest 2>/dev/null || true
            [[ "$SHOW_PROGRESS" -eq 1 || ( -t 1 && "$QUIET" -eq 0 ) ]] && printf "\033[?25h\n\033[1;33m⚠️ Profiling aborted by user.\033[0m\n"
            exit 130
        fi
    fi

    if [[ "$SHOW_PROGRESS" -eq 1 || ( -t 1 && "$QUIET" -eq 0 ) ]]; then
        # Live sample intermediate RSS
        curr_rss=$(awk '/^VmRSS:/ {print $2}' "/proc/$PID/status" 2>/dev/null || echo "$T0_RSS")
        curr_rss_mb=$(( curr_rss / 1024 ))
        delta_rss_mb=$(( (curr_rss - T0_RSS) / 1024 ))
        delta_sign=""
        (( delta_rss_mb > 0 )) && delta_sign="+"

        # Progress bar (32 chars)
        bar_len=32
        filled=$(( (elapsed * bar_len) / DURATION ))
        (( filled > bar_len )) && filled=$bar_len
        empty=$(( bar_len - filled ))

        bar_str="$(printf '█%.0s' $(seq 1 $filled 2>/dev/null || true))$(printf '░%.0s' $(seq 1 $empty 2>/dev/null || true))"

        # Cursor up 5 lines
        printf "\033[5A"
        printf "   \033[1;36m[%s]\033[0m \033[1;33m%2ds / %ds\033[0m \033[2;37m(%d%%)\033[0m\033[K\n" "$bar_str" "$elapsed" "$DURATION" "$(( elapsed * 100 / DURATION ))"
        printf "   \033[1;37mMemory:\033[0m %4d MB  \033[2;37m(Live Δ:\033[0m \033[1;%sm%s%d MB\033[0m\033[2;37m)\033[0m  \033[2;37m│\033[0m  \033[1;37mSockets:\033[0m %d\033[K\n" \
            "$curr_rss_mb" \
            "$(( delta_rss_mb > 0 ? 31 : (delta_rss_mb < 0 ? 32 : 37) ))" \
            "$delta_sign" "$delta_rss_mb" \
            "$T0_SOCK_COUNT"
        printf "   \033[2;37mSampling active heap and socket handles in /proc/%d...\033[0m\033[K\n" "$PID"
        printf "\n"
        printf "   \033[2;38;5;244mPress [Esc] to cancel profiling and return\033[0m\033[K\n"
    fi
done

if [[ "$SHOW_PROGRESS" -eq 1 || ( -t 1 && "$QUIET" -eq 0 ) ]]; then
    printf "\033[?25h" # Restore cursor
fi

# 6. Capture final snapshot T1
sample_metrics "$PID" "T1" || {
    echo "Failed to capture final metrics for PID $PID" >&2
    exit 1
}

# Freeze the process immediately after sampling to halt runaway execution and preserve state
kill -STOP "$PID" 2>/dev/null || true
WAS_PAUSED=1

# 7. Compute Differential Deltas
DELTA_SECS=$(( T1_TIME - T0_TIME ))
(( DELTA_SECS <= 0 )) && DELTA_SECS=1

DELTA_USS_KB=$(( T1_USS - T0_USS ))
DELTA_USS_MB=$(( DELTA_USS_KB / 1024 ))

DELTA_PSS_KB=$(( T1_PSS - T0_PSS ))
DELTA_PSS_MB=$(( DELTA_PSS_KB / 1024 ))

DELTA_RSS_KB=$(( T1_RSS - T0_RSS ))
DELTA_RSS_MB=$(( DELTA_RSS_KB / 1024 ))

DELTA_DATA_KB=$(( T1_DATA - T0_DATA ))
DELTA_DATA_MB=$(( DELTA_DATA_KB / 1024 ))

DELTA_SWAP_KB=$(( T1_SWAP - T0_SWAP ))
DELTA_SWAP_MB=$(( DELTA_SWAP_KB / 1024 ))

DELTA_ANON_KB=$(( T1_ANON - T0_ANON ))
DELTA_ANON_MB=$(( DELTA_ANON_KB / 1024 ))

DELTA_THREADS=$(( T1_THREADS - T0_THREADS ))
DELTA_FDS=$(( T1_FD_COUNT - T0_FD_COUNT ))
DELTA_SOCKS=$(( T1_SOCK_COUNT - T0_SOCK_COUNT ))
DELTA_PIPES=$(( T1_PIPE_COUNT - T0_PIPE_COUNT ))
DELTA_FILES=$(( T1_FILE_COUNT - T0_FILE_COUNT ))

# Memory velocity calculation (MB/min) using portable AWK
VELOCITY_MB_MIN=$(awk -v d_kb="$DELTA_USS_KB" -v dur="$DELTA_SECS" 'BEGIN { printf "%.1f", (d_kb * 60) / (dur * 1024) }')

# CPU calculation across window
CLK_TCK=$(getconf CLK_TCK 2>/dev/null || echo 100)
DELTA_UTIME=$(( T1_UTIME - T0_UTIME ))
DELTA_STIME=$(( T1_STIME - T0_STIME ))
TOTAL_TICKS=$(( DELTA_UTIME + DELTA_STIME ))
CPU_PCT=$(awk -v ticks="$TOTAL_TICKS" -v tck="$CLK_TCK" -v dur="$DELTA_SECS" 'BEGIN {
    pct = (ticks * 100) / (tck * dur);
    if (pct < 0) pct = 0;
    printf "%.1f", pct;
}')

# FD Diffing: identify newly opened sockets / files
declare -A T0_MAP=()
for item in "${T0_FD_TARGETS[@]}"; do
    [[ -n "$item" ]] && T0_MAP["$item"]=1
done

NEW_FD_SAMPLES=()
for item in "${T1_FD_TARGETS[@]}"; do
    [[ -z "$item" ]] && continue
    if [[ -z "${T0_MAP["$item"]:-}" ]]; then
        # Check if already in NEW_FD_SAMPLES
        if [[ ${#NEW_FD_SAMPLES[@]} -lt 5 ]]; then
            NEW_FD_SAMPLES+=("$item")
        fi
    fi
done

# 8. Diagnostic Classification Verdict
VERDICT="ℹ️ MINIMAL VARIATION"
VERDICT_DETAIL="Observed stable or minor footprint variation (+${DELTA_USS_MB} MB) within normal operating bounds."

# Evaluate leak severity using AWK for floating point comparisons
IS_RUNAWAY=$(awk -v d_mb="$DELTA_USS_MB" -v rate="$VELOCITY_MB_MIN" 'BEGIN {
    if (d_mb >= 5 && rate >= 15.0) print 1; else print 0;
}')

if [[ "$IS_RUNAWAY" -eq 1 ]]; then
    VERDICT="🚨 ACTIVE RUNAWAY HEAP LEAK"
    VERDICT_DETAIL="The application is actively allocating heap memory at ~${VELOCITY_MB_MIN} MB/min without garbage collection or release. Private dirty memory expanded by +${DELTA_USS_MB} MB during the ${DELTA_SECS}s window."
elif (( DELTA_SOCKS >= 8 )); then
    VERDICT="⚠️ NETWORK SOCKET / FD LEAK"
    VERDICT_DETAIL="The application accumulated +${DELTA_SOCKS} unclosed network sockets during the ${DELTA_SECS}s profiling window (possible connection leak or socket descriptor exhaustion)."
elif (( DELTA_THREADS >= 5 )); then
    VERDICT="⚠️ THREAD EXPLOSION / LEAK"
    VERDICT_DETAIL="Thread count increased by +${DELTA_THREADS} threads without recycling existing workers."
elif (( DELTA_USS_KB <= 1024 && DELTA_USS_KB >= -1024 )); then
    VERDICT="✅ STABLE FOOTPRINT / BOUNDED CACHE"
    VERDICT_DETAIL="Memory footprint remained virtually flat (Δ ${DELTA_USS_MB} MB) across ${DELTA_SECS}s. Memory usage represents an established working set or bounded cache rather than an ongoing runaway leak."
elif (( DELTA_USS_KB < -1024 )); then
    VERDICT="❄️ MEMORY RECLAIMED / GC CYCLE"
    VERDICT_DETAIL="Memory decreased by ${DELTA_USS_MB#-} MB during observation, indicating active memory trimming or garbage collection."
fi

# 9. Format Markdown Report
SIGN_USS=$(( DELTA_USS_MB > 0 ? 1 : 0 ))
USS_SIGN=""
(( SIGN_USS == 1 )) && USS_SIGN="+"

SIGN_PSS=$(( DELTA_PSS_MB > 0 ? 1 : 0 ))
PSS_SIGN=""
(( SIGN_PSS == 1 )) && PSS_SIGN="+"

SIGN_RSS=$(( DELTA_RSS_MB > 0 ? 1 : 0 ))
RSS_SIGN=""
(( SIGN_RSS == 1 )) && RSS_SIGN="+"

SIGN_DATA=$(( DELTA_DATA_MB > 0 ? 1 : 0 ))
DATA_SIGN=""
(( SIGN_DATA == 1 )) && DATA_SIGN="+"

FD_SIGN=""
(( DELTA_FDS > 0 )) && FD_SIGN="+"

SOCK_SIGN=""
(( DELTA_SOCKS > 0 )) && SOCK_SIGN="+"

REPORT=$(cat <<EOF
### 📸 ${DELTA_SECS}-Second Differential Memory Snapshot Profile
- **Target Process:** \`$COMM\` (PID $PID)
- **Observation Window:** ${DELTA_SECS} seconds (\$T_0 \to T_{${DELTA_SECS}}\$)
- **Diagnostic Verdict:** **$VERDICT**

#### 1. Memory Dynamics & Allocation Velocity
| Metric | \$T_0\$ | \$T_{${DELTA_SECS}}\$ | Delta (\$\\Delta\$) | Rate of Change |
| :--- | :--- | :--- | :--- | :--- |
| **Unique Set (USS)** | $(( T0_USS / 1024 )) MB | $(( T1_USS / 1024 )) MB | **${USS_SIGN}${DELTA_USS_MB} MB** | **${VELOCITY_MB_MIN} MB/min** |
| **Proportional (PSS)** | $(( T0_PSS / 1024 )) MB | $(( T1_PSS / 1024 )) MB | ${PSS_SIGN}${DELTA_PSS_MB} MB | — |
| **Resident Set (RSS)** | $(( T0_RSS / 1024 )) MB | $(( T1_RSS / 1024 )) MB | ${RSS_SIGN}${DELTA_RSS_MB} MB | — |
| **Heap / Data (VmData)** | $(( T0_DATA / 1024 )) MB | $(( T1_DATA / 1024 )) MB | ${DATA_SIGN}${DELTA_DATA_MB} MB | — |
| **Swap Usage** | $(( T0_SWAP / 1024 )) MB | $(( T1_SWAP / 1024 )) MB | $(( DELTA_SWAP_MB )) MB | — |

#### 2. File Descriptors & Sockets
- **Total Descriptors:** $T0_FD_COUNT $\to$ $T1_FD_COUNT (Δ ${FD_SIGN}${DELTA_FDS})
- **Network Sockets:** $T0_SOCK_COUNT $\to$ $T1_SOCK_COUNT (Δ ${SOCK_SIGN}${DELTA_SOCKS})
- **Pipes:** $T0_PIPE_COUNT $\to$ $T1_PIPE_COUNT
- **Regular Files:** $T0_FILE_COUNT $\to$ $T1_FILE_COUNT
EOF
)

if [[ ${#NEW_FD_SAMPLES[@]} -gt 0 ]]; then
    REPORT+=$'\n- **Sample of Newly Created Descriptors:**\n'
    for s in "${NEW_FD_SAMPLES[@]}"; do
        s_clean=$(printf '%s' "$s" | tr -cd '[:print:]')
        REPORT+=$(printf '  • `%s`\n' "$s_clean")
    done
fi

REPORT+=$(cat <<EOF

#### 3. Execution & Thread Metrics
- **Thread Count:** $T0_THREADS $\to$ $T1_THREADS ($\Delta$ $DELTA_THREADS)
- **CPU Activity:** ${CPU_PCT}% utilization across observation window

#### 4. Mechanistic Assessment
$VERDICT_DETAIL
EOF
)

# 10. Output results
if [[ -n "$OUTPUT_FILE" ]]; then
    printf "%s\n" "$REPORT" > "$OUTPUT_FILE"
    if [[ "$QUIET" -eq 0 && ( -t 1 || "$SHOW_PROGRESS" -eq 1 ) ]]; then
        printf "  \033[1;32m✓ Differential snapshot captured:\033[0m \033[1;37m%s\033[0m\n" "$VERDICT"
        printf "  \033[2;37mMemory velocity: %s MB/min • Written to: %s\033[0m\n\n" "$VELOCITY_MB_MIN" "$OUTPUT_FILE"
    fi
else
    printf "%s\n" "$REPORT"
fi

exit 0
