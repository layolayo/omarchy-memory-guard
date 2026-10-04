#!/bin/bash
set -u

# Request snug terminal resize (if supported)
LOGO=$(cat << 'ASCII'
  ██████╗ ███╗   ███╗ █████╗ ██████╗  █████╗ ███╗   ███╗
 ██╔═══██╗████╗ ████║██╔══██╗██╔══██╗██╔══██╗████╗ ████║
 ██║   ██║██╔████╔██║███████║██████╔╝███████║██╔████╔██║
 ██║   ██║██║╚██╔╝██║██╔══██║██╔══██╗██╔══██║██║╚██╔╝██║
 ╚██████╔╝██║ ╚═╝ ██║██║  ██║██║  ██║██║  ██║██║ ╚═╝ ██║
  ╚═════╝ ╚═╝     ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝     ╚═╝
ASCII
)

# Set standard X11 window title
printf "\033]0;OMARAM-GUARD\007"

# Determine whether OMARAM is currently floating or tiled to show appropriate navigation hint:
# When floating -> 'super+t tile'
# When tiled    -> 'super+t float'
get_tile_action_label() {
    if [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
        local active_json is_omaram is_floating
        active_json=$(hyprctl activewindow -j 2>/dev/null || true)
        is_omaram=$(echo "$active_json" | jq -r '(.class == "org.omarchy.terminal.omaram" or .title == "OMARAM-GUARD") // false' 2>/dev/null || echo "false")

        if [[ "$is_omaram" == "true" ]]; then
            is_floating=$(echo "$active_json" | jq -r 'if .floating == false then "false" else "true" end' 2>/dev/null || echo "true")
        else
            is_floating=$(hyprctl clients -j 2>/dev/null | jq -r '.[] | select(.class == "org.omarchy.terminal.omaram" or .title == "OMARAM-GUARD") | if .floating == false then "false" else "true" end' 2>/dev/null | head -1)
        fi

        if [[ "$is_floating" == "false" ]]; then
            echo "float"
            return
        fi
    fi
    echo "tile"
}

# Auto-tile OMARAM window if it is currently floating so AI diagnosis fits side-by-side
tile_if_floating() {
    if [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
        hyprctl eval 'for _, w in ipairs(hl.get_windows()) do if w.class == "org.omarchy.terminal.omaram" or w.title == "OMARAM-GUARD" then if w.floating then hl.dispatch(hl.dsp.window.float({ window = w, action = "off" })) end; break end end' >/dev/null 2>&1 || true
    fi
}

# Detect whether a process is running inside a sandbox or container (Flatpak, Snap, bwrap, Docker, or isolated namespaces)
# to prevent sandbox escape vulnerabilities during process restart.
is_confined_or_sandboxed() {
    local target_pid="$1"
    [[ -d "/proc/$target_pid" ]] || return 1

    # 1. Mount namespace check: If target mount namespace differs from host shell
    local host_mnt target_mnt
    host_mnt=$(readlink "/proc/$$/ns/mnt" 2>/dev/null || readlink "/proc/1/ns/mnt" 2>/dev/null || true)
    target_mnt=$(readlink "/proc/$target_pid/ns/mnt" 2>/dev/null || true)
    if [[ -n "$host_mnt" && -n "$target_mnt" && "$host_mnt" != "$target_mnt" ]]; then
        return 0
    fi

    # 2. User namespace check
    local host_user target_user
    host_user=$(readlink "/proc/$$/ns/user" 2>/dev/null || readlink "/proc/1/ns/user" 2>/dev/null || true)
    target_user=$(readlink "/proc/$target_pid/ns/user" 2>/dev/null || true)
    if [[ -n "$host_user" && -n "$target_user" && "$host_user" != "$target_user" ]]; then
        return 0
    fi

    # 3. PID namespace check
    local host_pid_ns target_pid_ns
    host_pid_ns=$(readlink "/proc/$$/ns/pid" 2>/dev/null || true)
    target_pid_ns=$(readlink "/proc/$target_pid/ns/pid" 2>/dev/null || true)
    if [[ -n "$host_pid_ns" && -n "$target_pid_ns" && "$host_pid_ns" != "$target_pid_ns" ]]; then
        return 0
    fi

    # 4. Root filesystem check: Chroot or alternate root
    local target_root
    target_root=$(readlink -f "/proc/$target_pid/root" 2>/dev/null || true)
    if [[ -n "$target_root" && "$target_root" != "/" ]]; then
        return 0
    fi

    # 5. Flatpak environment detection
    if [[ -e "/proc/$target_pid/root/.flatpak-info" ]]; then
        return 0
    fi

    # 6. Container or sandbox cgroups (Flatpak, Snap, Podman, Docker, bwrap)
    if grep -q -E "(app-flatpak|snap\.|docker|containerd|bwrap|sandbox)" "/proc/$target_pid/cgroup" 2>/dev/null; then
        return 0
    fi

    return 1
}

# Watch for floating mode changes in background so the navigation hint updates live when super+t is pressed
FLOAT_CHANGED_FLAG=$(mktemp -t omaram-float-XXXXXX 2>/dev/null || echo "/tmp/omaram-float-$$.flag")
CURRENT_TTY=$(tty 2>/dev/null || true)
CURRENT_TTY_NAME="${CURRENT_TTY#/dev/}"

watch_floating_state() {
    local last_state
    last_state=$(get_tile_action_label)
    while true; do
        sleep 0.25
        local cur_state
        cur_state=$(get_tile_action_label)
        if [[ -n "$last_state" && "$cur_state" != "$last_state" ]]; then
            touch "$FLOAT_CHANGED_FLAG"
            if [[ -n "$CURRENT_TTY_NAME" ]]; then
                pkill -t "$CURRENT_TTY_NAME" -x gum 2>/dev/null || true
            fi
        fi
        last_state="$cur_state"
    done
}

ESC=$'\e'

# Interactive in-place selector that cleanly places instructions at the bottom
# and restricts navigation strictly to the items (never allowing blank line or instructions to be selected)
omaram_choose() {
    local -n _items=$1
    local _header="$2"
    local _footer_fmt="$3"
    local _out_var="$4"
    local _color="${5:-196}"
    local _selected=0
    local _num=${#_items[@]}
    local ESC=$'\e'
    [ "$_num" -eq 0 ] && return 1

    printf "\033[?25l"
    trap 'printf "\033[?25h"' RETURN INT TERM

    [ -n "$_header" ] && printf "%s\n" "$_header"

    _draw() {
        local i _lbl _footer
        for ((i=0; i<_num; i++)); do
            if [ "$i" -eq "$_selected" ]; then
                printf "\r\033[K \033[38;5;%smᐅ %s\033[0m\n" "$_color" "${_items[$i]}"
            else
                printf "\r\033[K   %s\n" "${_items[$i]}"
            fi
        done
        printf "\r\033[K\n"
        _lbl=$(get_tile_action_label)
        printf -v _footer "$_footer_fmt" "$_lbl"
        printf "\r\033[K %s" "$_footer"
    }

    _draw

    while true; do
        local key=""
        IFS= read -rsn1 -t 0.15 key
        local status=$?

        # Timeout (>128): check if Hyprland float state changed in background
        if [ "$status" -gt 128 ]; then
            if [ -f "$FLOAT_CHANGED_FLAG" ]; then
                rm -f "$FLOAT_CHANGED_FLAG"
                printf "\033[%dA" "$((_num + 1))"
                _draw
            fi
            continue
        elif [ "$status" -ne 0 ]; then
            # EOF or read error (e.g. terminal disconnected or piped input closed)
            printf "\033[?25h"
            return 130
        fi

        if [[ "$key" == "$ESC" ]]; then
            local rest=""
            IFS= read -rsn2 -t 0.05 rest || true
            if [[ "$rest" == "[A" || "$rest" == "OA" ]]; then
                _selected=$(( (_selected - 1 + _num) % _num ))
                printf "\033[%dA" "$((_num + 1))"
                _draw
            elif [[ "$rest" == "[B" || "$rest" == "OB" ]]; then
                _selected=$(( (_selected + 1) % _num ))
                printf "\033[%dA" "$((_num + 1))"
                _draw
            elif [ -z "$rest" ]; then
                printf "\033[?25h"
                return 130
            fi
        elif [[ "$key" == "k" ]]; then
            _selected=$(( (_selected - 1 + _num) % _num ))
            printf "\033[%dA" "$((_num + 1))"
            _draw
        elif [[ "$key" == "j" ]]; then
            _selected=$(( (_selected + 1) % _num ))
            printf "\033[%dA" "$((_num + 1))"
            _draw
        elif [[ "$key" == $'\x03' ]]; then
            printf "\033[?25h"
            return 130
        elif [[ "$key" == "" ]]; then
            printf "\033[?25h"
            printf -v "$_out_var" "%s" "${_items[$_selected]}"
            return 0
        fi
    done
}

if [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
    watch_floating_state &
    WATCHER_PID=$!
    trap 'rm -f "$FLOAT_CHANGED_FLAG"; kill "$WATCHER_PID" 2>/dev/null || true' EXIT
else
    trap 'rm -f "$FLOAT_CHANGED_FLAG"' EXIT
fi

while true; do
    clear

    gum style --foreground 51 --margin "1 0 0 2" "$LOGO"
    # Logo is 56 chars. Subtitle is 39 chars. Margin of 10 perfectly centers it under the logo (2 + 8).
    gum style --foreground 51 --margin "0 0 1 10" "The High Memory Guard & Diagnostic Tool"

    # Memory Stats Box with Linux PSI (Pressure Stall Information)
    PSI_VAL=$(awk '/^some/ {for (i=1; i<=NF; i++) if ($i ~ /^avg10=/) {sub("avg10=", "", $i); print $i"%"}}' /proc/pressure/memory 2>/dev/null || echo "N/A")
    MEM_STATS=$(free -h | head -n 2 | awk -v psi="${PSI_VAL:-N/A}" '
        NR==1 {print "Total\tUsed\tFree\tShared\tCache\tAvail\tPSI"}
        NR==2 {print $2"\t"$3"\t"$4"\t"$5"\t"$6"\t"$7"\t"psi}
    ' | sed 's/Gi/G/g; s/Mi/M/g' | column -t -s $'\t' -R 1,2,3,4,5,6,7)
    MEM_STATS=$(echo "$MEM_STATS" | sed $'s/.*/\033[38;5;135m&\033[0m/')
    MEM_BOX=$(gum style --border rounded --padding "0 1" "$MEM_STATS")
    MEM_BOX=$(echo "$MEM_BOX" | sed $'s/.*/\033[38;5;135m&\033[0m/')
    gum style --margin "0 4" "$MEM_BOX"
    
    # Process List: Filter by UID, exclude self/parent/wrappers, and aggregate multi-process trees
    LIST=$(ps -u "$UID" --no-headers -o pid,ppid,rss,pmem,state,comm 2>/dev/null | awk -v self="$$" -v parent="$PPID" '
        BEGIN {
            ignore["omaram"] = 1; ignore["omaram-guard"] = 1; ignore["gum"] = 1;
            ignore["bash"] = 1; ignore["ps"] = 1; ignore["xdg-terminal-exec"] = 1;
        }
        {
            pid = $1; ppid = $2; rss = $3; pmem = $4; state = $5; comm = $6;
            if (pid == self || pid == parent || comm in ignore) next;

            P_pid[pid] = pid
            P_ppid[pid] = ppid
            P_rss[pid] = rss
            P_pmem[pid] = pmem
            P_state[pid] = state
            P_comm[pid] = comm
            all_pids[++num_pids] = pid
        }
        function find_group_root(p, c) {
            curr = p
            while ((curr in P_ppid) && (P_ppid[curr] in P_comm) && P_comm[P_ppid[curr]] == c) {
                curr = P_ppid[curr]
            }
            return curr
        }
        END {
            for (i = 1; i <= num_pids; i++) {
                p = all_pids[i]
                c = P_comm[p]
                r = find_group_root(p, c)
                if (!(r in group_pids)) {
                    group_list[++num_groups] = r
                    group_pids[r] = 1
                    group_comm[r] = c
                    group_count[r] = 0
                    group_rss[r] = 0
                    group_pmem[r] = 0
                    group_state[r] = "S"
                }
                group_count[r] += 1
                group_rss[r] += P_rss[p]
                group_pmem[r] += P_pmem[p]
                if (P_state[p] ~ /^T/) group_state[r] = "T"
            }
            for (g = 1; g <= num_groups; g++) {
                r = group_list[g]
                cnt = group_count[r]
                comm = group_comm[r]
                label = (cnt > 1) ? comm " (" cnt " procs)" : comm
                tag = (group_state[r] ~ /^T/ ? " ⏸️ PAUSED" : "")
                printf "%8s %7d MB %6.1f%%    %s%s\n", r, int(group_rss[r]/1024), group_pmem[r], label, tag
            }
        }' | sort -k2 -n -r | head -n 5)

    mapfile -t PROC_LIST < <(printf "%s" "$LIST" | grep -v '^[[:space:]]*$')

    if [ ${#PROC_LIST[@]} -eq 0 ]; then
        gum style --foreground 220 --margin "1 7" "No high memory processes found."
        sleep 1.5
        continue
    fi

    COLUMNS=$(printf "   %8s %10s %7s    %s" "PID" "RAM" "MEM %" "APP")
    HEADER_TEXT=$(printf "\n\033[1;33mTop 5 Memory Consumers:\033[0m\n\033[1;36m%s\033[0m" "$COLUMNS")
    NAV_HELP="\033[2;38;5;244m↑↓ navigate • enter submit • super+t %s • esc quit\033[0m"

    TARGET=""
    if ! omaram_choose PROC_LIST "$HEADER_TEXT" "$NAV_HELP" TARGET "208"; then
        exit 130
    fi

    # If layout switched between tiled and floating while user was on screen, refresh cleanly
    if [ -f "$FLOAT_CHANGED_FLAG" ]; then
        rm -f "$FLOAT_CHANGED_FLAG"
        continue
    fi

    if [ -z "$TARGET" ]; then
        exit 130
    fi

    PID=$(echo "$TARGET" | awk '{print $1}')
    
    # Security validation: Ensure PID is numeric, > 1, and not self/parent
    if [[ ! "$PID" =~ ^[0-9]+$ ]] || [ "$PID" -le 1 ] || [ "$PID" -eq "$$" ] || [ "$PID" -eq "$PPID" ]; then
        continue
    fi

    # Security validation: Ensure process exists and belongs to current user
    if [[ ! -d "/proc/$PID" ]]; then
        continue
    fi
    PROC_UID=$(stat -c '%u' "/proc/$PID" 2>/dev/null || true)
    if [[ "$PROC_UID" != "$UID" ]]; then
        continue
    fi

    NAME=$(cat "/proc/$PID/comm" 2>/dev/null || echo "process")
    NAME=${NAME##*/}
    [[ -n $NAME && $NAME != "-" && $NAME != "." && $NAME != ".." ]] || NAME="process"
    NAME=$(printf '%s' "$NAME" | tr -cd '[:print:]')
    [ -z "$NAME" ] && NAME="process"

    # Extract USS (Private_Clean + Private_Dirty) and PSS for True Reclaim metric
    USS_KB=0
    PSS_KB=0
    if [[ -r "/proc/$PID/smaps_rollup" ]]; then
        read -r USS_KB PSS_KB < <(awk '
            /^Private_(Clean|Dirty):/ {uss += $2}
            /^Pss:/ {pss += $2}
            END {print (uss ? uss : 0), (pss ? pss : 0)}
        ' "/proc/$PID/smaps_rollup" 2>/dev/null || echo "0 0")
    fi
    USS_MB=$(( USS_KB / 1024 ))
    PSS_MB=$(( PSS_KB / 1024 ))

    clear
    gum style --foreground 51 --margin "1 0 0 2" "$LOGO"
    gum style --foreground 51 --margin "0 0 1 10" "The High Memory Guard & Diagnostic Tool"
    
    # Process Header Details: Selected process with True Reclaim (USS) and PSS
    HEADER_DETAILS="Selected: $NAME (PID $PID)"
    if [ "$USS_MB" -gt 0 ]; then
        HEADER_DETAILS+=$'\n'"True Reclaim (USS): ${USS_MB} MB • PSS: ${PSS_MB} MB"
    fi
    gum style --border normal --border-foreground 196 --foreground 196 --width 45 --align center --margin "1 5" "$HEADER_DETAILS"

    PROC_STATE=$(awk '/^State:/ {print $2}' "/proc/$PID/status" 2>/dev/null || echo "S")

    if [ "$PROC_STATE" = "T" ]; then
        ACTION_HEADER=$(printf "\033[1;33mSelect Action \033[1;35m(Status: PAUSED)\033[0m:")
        TOGGLE_ACTION="▶️ Resume (SIGCONT)"
        AI_ACTION="🤖 Diagnose with AI (Inspect Paused)"
    else
        ACTION_HEADER=$(printf "\033[1;33mSelect Action \033[1;32m(Status: RUNNING)\033[0m:")
        TOGGLE_ACTION="⏸️ Pause (SIGSTOP)"
        AI_ACTION="🤖 Diagnose with AI (SIGSTOP)"
    fi

    ACTION_ITEMS=(
        "💀 Kill Process"
        "🔄 Restart Process"
        "$TOGGLE_ACTION"
        "$AI_ACTION"
        "🔙 Back to List"
    )
    ACTION_NAV="\033[2;38;5;244m↑↓ navigate • enter submit • super+t %s • esc back\033[0m"

    ACTION=""
    if ! omaram_choose ACTION_ITEMS "$ACTION_HEADER" "$ACTION_NAV" ACTION "196"; then
        continue
    fi

    case "$ACTION" in
        *"Kill"*)
            mapfile -t CHILD_PIDS < <(pgrep -P "$PID" 2>/dev/null || true)
            kill -9 "$PID" "${CHILD_PIDS[@]}" 2>/dev/null || true
            gum style --foreground 196 --margin "1 2" "💀 Killed $NAME."
            sleep 1.5
            ;;
        *"Restart"*)
            # Security verification: Preserve sandbox boundaries and prevent sandbox escape.
            # A confined same-user application without host-execution permissions must not be executed on the host.
            if is_confined_or_sandboxed "$PID"; then
                local flatpak_app_id=""
                if [[ -f "/proc/$PID/root/.flatpak-info" ]]; then
                    flatpak_app_id=$(awk -F= '/^app-id=/ {print $2}' "/proc/$PID/root/.flatpak-info" 2>/dev/null || true)
                fi

                if [[ -n "$flatpak_app_id" && "$flatpak_app_id" =~ ^[a-zA-Z0-9._-]+$ ]] && command -v flatpak >/dev/null 2>&1; then
                    kill -9 "$PID" 2>/dev/null || true
                    sleep 0.5
                    (cd "$HOME" && flatpak run "$flatpak_app_id" </dev/null >/dev/null 2>&1 & disown)
                    gum style --foreground 46 --margin "1 2" "🔄 Restarted $NAME via Flatpak sandbox launcher."
                    sleep 1.5
                else
                    # For all other confined processes (containers, namespaces, bwrap, custom sandboxes),
                    # skip host restart to preserve the sandbox boundary and prevent host code execution.
                    gum style --foreground 220 --margin "1 2" "⚠️ $NAME is running inside a sandbox/container."
                    gum style --foreground 244 --margin "0 2" "Host restart skipped for security; please use its application launcher."
                    sleep 3
                fi
                continue
            fi

            # For unconfined host processes:
            # 1. Resolve safe working directory
            CWD=$(readlink -f "/proc/$PID/cwd" 2>/dev/null || echo "$HOME")
            if [[ ! -d "$CWD" ]]; then
                CWD="$HOME"
            fi

            # 2. Kernel-verified binary from /proc/$PID/exe (cannot be forged by user process)
            EXE=$(readlink -f "/proc/$PID/exe" 2>/dev/null || true)
            if [[ -z "$EXE" || "$EXE" != /* || ! -f "$EXE" || ! -x "$EXE" ]]; then
                gum style --foreground 196 --margin "1 2" "❌ Cannot restart $NAME: binary missing or not executable."
                sleep 2
                continue
            fi

            # 3. Read cmdline arguments
            mapfile -d '' CMD_ARGS < "/proc/$PID/cmdline" 2>/dev/null || true

            # 4. Enforce that the invoked executable is ALWAYS the verified kernel EXE,
            # never an arbitrary or mutated string in CMD_ARGS[0].
            CMD_ARGS[0]="$EXE"

            # 5. Prevent interpreter code injection via mutated arguments:
            # If the binary is a shell or interpreter, reject inline execution flags (-c, -e, --eval, --command)
            local exe_basename="${EXE##*/}"
            local has_inline_code=0
            if [[ "$exe_basename" =~ ^(bash|sh|zsh|dash|python.*|perl|ruby|node|php)$ ]]; then
                for arg in "${CMD_ARGS[@]:1}"; do
                    if [[ "$arg" == "-c" || "$arg" == "-e" || "$arg" == "--eval" || "$arg" == "--command" ]]; then
                        has_inline_code=1
                        break
                    fi
                done
            fi

            if [ "$has_inline_code" -eq 1 ]; then
                gum style --foreground 196 --margin "1 2" "❌ Cannot restart $NAME: inline interpreter code arguments rejected for safety."
                sleep 2
                continue
            fi

            mapfile -t CHILD_PIDS < <(pgrep -P "$PID" 2>/dev/null || true)
            kill -9 "$PID" "${CHILD_PIDS[@]}" 2>/dev/null || true
            sleep 0.5
            (cd "$CWD" && "${CMD_ARGS[@]}" </dev/null >/dev/null 2>&1 & disown)
            gum style --foreground 46 --margin "1 2" "🔄 Restarted $NAME cleanly."
            sleep 1.5
            ;;
        *"Diagnose"*)
            tile_if_floating
            SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
            "$SCRIPT_DIR/omaram-diagnose.sh" "$PID" >/dev/null 2>&1 &
            gum style --foreground 51 --margin "1 2" "⏸️ Paused $NAME & launched AI diagnostic agent."
            sleep 2.5
            ;;
        *"Pause"*)
            mapfile -t CHILD_PIDS < <(pgrep -P "$PID" 2>/dev/null || true)
            kill -STOP "$PID" "${CHILD_PIDS[@]}" 2>/dev/null || true
            gum style --foreground 220 --margin "1 2" "⏸️ Paused $NAME. Execution suspended."
            sleep 2
            ;;
        *"Resume"*)
            mapfile -t CHILD_PIDS < <(pgrep -P "$PID" 2>/dev/null || true)
            kill -CONT "$PID" "${CHILD_PIDS[@]}" 2>/dev/null || true
            gum style --foreground 46 --margin "1 2" "▶️ Resumed $NAME."
            sleep 1.5
            ;;
        *)
            continue
            ;;
    esac
done
