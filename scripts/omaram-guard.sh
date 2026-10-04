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
HYPR_EVENT_FLAG=$(mktemp -t omaram-event-XXXXXX 2>/dev/null || echo "/tmp/omaram-event-$$.flag")
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

watch_hyprland_events() {
    local sock="${XDG_RUNTIME_DIR:-/run/user/$UID}/hypr/${HYPRLAND_INSTANCE_SIGNATURE:-}/.socket2.sock"
    if [ ! -S "$sock" ]; then
        return 0
    fi
    socat -u "UNIX-CONNECT:$sock" - 2>/dev/null | while read -r raw_event; do
        case "$raw_event" in
            activewindow*|workspace*|focusedmon*)
                touch "$HYPR_EVENT_FLAG"
                ;;
        esac
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
    local _indent="${6:-0}"
    local _initial_sel="${7:-0}"
    local _listen_events="${8:-0}"
    local _selected="$_initial_sel"
    local _num=${#_items[@]}
    local ESC=$'\e'
    [ "$_num" -eq 0 ] && return 1

    [ "$_selected" -ge "$_num" ] && _selected=0
    [ "$_selected" -lt 0 ] && _selected=0

    # Clear any stale event flags before drawing fresh menu
    if [ "$_listen_events" -eq 1 ]; then
        rm -f "$HYPR_EVENT_FLAG" 2>/dev/null || true
    fi

    printf "\033[?25l"
    trap 'printf "\033[?25h"' RETURN INT TERM

    if [ -n "$_header" ]; then
        if [ "$_indent" -gt 0 ]; then
            while IFS= read -r hline; do
                printf "%*s%b\n" "$_indent" "" "$hline"
            done <<< "$_header"
        else
            printf "%s\n" "$_header"
        fi
    fi

    _draw() {
        local i _lbl _footer
        local _pad_str=""
        if [ "$_indent" -gt 0 ]; then
            printf -v _pad_str "%*s" "$_indent" ""
        fi
        for ((i=0; i<_num; i++)); do
            if [ "$i" -eq "$_selected" ]; then
                printf "\r\033[K%s \033[38;5;%smᐅ %s\033[0m\n" "$_pad_str" "$_color" "${_items[$i]}"
            else
                printf "\r\033[K%s   %s\n" "$_pad_str" "${_items[$i]}"
            fi
        done
        printf "\r\033[K\n"
        _lbl=$(get_tile_action_label)
        printf -v _footer "$_footer_fmt" "$_lbl"
        local _stripped _fpad
        _stripped=$(printf "%b" "$_footer" | sed -E "s/\x1B\[[0-9;]*[a-zA-Z]//g")
        _fpad=$(( (64 - ${#_stripped}) / 2 ))
        [ "$_fpad" -lt 0 ] && _fpad=0
        printf "\r\033[K%*s%b" "$_fpad" "" "$_footer"
    }

    _draw

    while true; do
        local key=""
        IFS= read -rsn1 -t 0.15 key
        local status=$?

        # Timeout (>128): check if Hyprland float state or focus/workspace changed in background
        if [ "$status" -gt 128 ]; then
            if [ -f "$FLOAT_CHANGED_FLAG" ]; then
                rm -f "$FLOAT_CHANGED_FLAG"
                printf "\033[%dA" "$((_num + 1))"
                _draw
            fi
            if [ "$_listen_events" -eq 1 ] && [ -f "$HYPR_EVENT_FLAG" ]; then
                rm -f "$HYPR_EVENT_FLAG"
                printf "\033[?25h"
                LAST_SELECTED_INDEX="$_selected"
                return 200
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
            LAST_SELECTED_INDEX=0
            printf -v "$_out_var" "%s" "${_items[$_selected]}"
            return 0
        fi
    done
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VELOCITY_CACHE=$(mktemp -t omaram-vel-XXXXXX 2>/dev/null || echo "/tmp/omaram-vel-$$.cache")
CLIENT_MAP_CACHE=$(mktemp -t omaram-clients-XXXXXX 2>/dev/null || echo "/tmp/omaram-clients-$$.cache")
NAP_REGISTRY_FILE="${XDG_RUNTIME_DIR:-/run/user/$UID}/omaram/nap.registry"
NAP_SCRIPT="$SCRIPT_DIR/omaram-nap-watcher.sh"

show_feedback() {
    local color="$1"
    local title="$2"
    local subtitle="${3:-}"
    local delay="${4:-1.2}"
    local msg="$title"
    if [ -n "$subtitle" ]; then
        msg=$(printf "%s\n%s" "$title" "$subtitle")
    fi

    clear
    gum style --foreground 51 --margin "1 0 0 5" "$LOGO"
    gum style --foreground 51 --margin "0 0 1 13" "The High Memory Guard & Diagnostic Tool"
    gum style --border normal --border-foreground "$color" --foreground "$color" --width 45 --align center --margin "0 10" "$msg"
    sleep "$delay"
}

if [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
    watch_floating_state &
    WATCHER_PID=$!
    watch_hyprland_events &
    EVENT_WATCHER_PID=$!
    trap 'rm -f "$FLOAT_CHANGED_FLAG" "$HYPR_EVENT_FLAG" "$VELOCITY_CACHE" "$CLIENT_MAP_CACHE"; kill "$WATCHER_PID" "$EVENT_WATCHER_PID" 2>/dev/null || true' EXIT
else
    trap 'rm -f "$FLOAT_CHANGED_FLAG" "$HYPR_EVENT_FLAG" "$VELOCITY_CACHE" "$CLIENT_MAP_CACHE"' EXIT
fi

while true; do
    clear

    # Logo is 56 chars. In 64-col terminal, margin of 5 centers it.
    gum style --foreground 51 --margin "1 0 0 5" "$LOGO"
    # Subtitle is 39 chars. Margin of 13 centers it.
    gum style --foreground 51 --margin "0 0 1 13" "The High Memory Guard & Diagnostic Tool"

    # Memory Stats Box with Linux PSI (Pressure Stall Information)
    PSI_VAL=$(awk '/^some/ {for (i=1; i<=NF; i++) if ($i ~ /^avg10=/) {sub("avg10=", "", $i); print $i"%"}}' /proc/pressure/memory 2>/dev/null || echo "N/A")
    MEM_STATS=$(free -h | head -n 2 | awk -v psi="${PSI_VAL:-N/A}" '
        NR==1 {print "Total\tUsed\tFree\tShared\tCache\tAvail\tPSI"}
        NR==2 {print $2"\t"$3"\t"$4"\t"$5"\t"$6"\t"$7"\t"psi}
    ' | sed 's/Gi/G/g; s/Mi/M/g' | column -t -s $'\t' -R 1,2,3,4,5,6,7)
    MEM_STATS=$(echo "$MEM_STATS" | sed $'s/.*/\033[38;5;135m&\033[0m/')
    MEM_BOX=$(gum style --border rounded --padding "0 1" "$MEM_STATS")
    MEM_BOX=$(echo "$MEM_BOX" | sed $'s/.*/\033[38;5;135m&\033[0m/')
    # Mem box is 50 chars with border. Margin of 8 centers it.
    gum style --margin "0 8" "$MEM_BOX"
    
    # Map running window classes so generic runtimes (java, python, node, electron) show real desktop app names
    hyprctl clients -j 2>/dev/null | jq -r '.[] | select(.pid > 0 and .class != "") | "\(.pid):\(.class)"' > "$CLIENT_MAP_CACHE" 2>/dev/null || true

    # Process List: Filter by UID, exclude self/parent/wrappers, and aggregate multi-process trees with velocity trends
    LIST=$(ps -u "$UID" --no-headers -o pid,ppid,rss,pmem,state,comm 2>/dev/null | awk -v self="$$" -v parent="$PPID" -v now="$(date +%s)" -v vel_file="$VELOCITY_CACHE" -v nap_file="$NAP_REGISTRY_FILE" -v client_file="$CLIENT_MAP_CACHE" '
        BEGIN {
            ignore["omaram"] = 1; ignore["omaram-guard"] = 1; ignore["gum"] = 1;
            ignore["bash"] = 1; ignore["ps"] = 1; ignore["xdg-terminal-exec"] = 1;
            generic["java"] = 1; generic["python"] = 1; generic["python3"] = 1;
            generic["node"] = 1; generic["electron"] = 1; generic["ruby"] = 1; generic["perl"] = 1;
            if (vel_file != "") {
                while ((getline vline < vel_file) > 0) {
                    split(vline, va, ":");
                    if (va[1] != "" && va[2] != "" && va[3] != "") {
                        prev_time[va[1]] = va[2];
                        prev_rss[va[1]] = va[3];
                    }
                }
                close(vel_file);
            }
            if (nap_file != "") {
                while ((getline nline < nap_file) > 0) {
                    split(nline, na, ":");
                    if (na[1] != "") nap_pids[na[1]] = 1;
                }
                close(nap_file);
            }
            if (client_file != "") {
                while ((getline cline < client_file) > 0) {
                    split(cline, ca, ":");
                    if (ca[1] != "" && ca[2] != "") win_class[ca[1]] = ca[2];
                }
                close(client_file);
            }
        }
        {
            pid = $1; ppid = $2; rss = $3; pmem = $4; state = $5; comm = $6;
            if (pid == self || pid == parent || comm in ignore) next;

            if (comm in generic) {
                if (pid in win_class) comm = win_class[pid];
                else if (ppid in win_class) comm = win_class[ppid];
            }

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
                    group_members[r] = ""
                }
                group_count[r] += 1
                group_rss[r] += P_rss[p]
                group_pmem[r] += P_pmem[p]
                group_members[r] = (group_members[r] == "" ? p : group_members[r] "," p)
                if (P_state[p] ~ /^T/) group_state[r] = "T"
            }
            for (g = 1; g <= num_groups; g++) {
                r = group_list[g]
                cnt = group_count[r]
                comm = group_comm[r]
                rss_mb = int(group_rss[r]/1024)
                label = (cnt > 1) ? comm " (" cnt " procs)" : comm
                if (length(label) > 18) {
                    label = (cnt > 1) ? comm " (" cnt "p)" : comm
                }
                if (length(label) > 18) {
                    label = substr(label, 1, 17) "…"
                }

                # Status tag: Minimal icons without words
                if (r in nap_pids) {
                    tag = (group_state[r] ~ /^T/ ? "💤" : "☀️")
                } else {
                    tag = (group_state[r] ~ /^T/ ? "⏸️" : "  ")
                }

                trend = "\033[38;5;244m→\033[0m"
                if (r in prev_time) {
                    dt = now - prev_time[r]
                    if (dt >= 1 && dt <= 120) {
                        drss = rss_mb - prev_rss[r]
                        rate = (drss * 60) / dt
                        if (rate >= 30) trend = "\033[1;31m↑\033[0m"
                        else if (rate <= -30) trend = "\033[1;32m↓\033[0m"
                    }
                }
                new_vel[r] = r ":" now ":" rss_mb

                printf "%8s %7d MB   %s   %6.1f%%    %-18s %s | %s\n", r, rss_mb, trend, group_pmem[r], label, tag, group_members[r]
            }

            if (vel_file != "") {
                for (vr in new_vel) print new_vel[vr] > vel_file
                close(vel_file)
            }
        }' | sort -k2 -n -r | head -n 5)

    declare -A GROUP_MEMBERS_MAP
    PROC_LIST=()
    while IFS='|' read -r display_line members; do
        display_line=$(echo "$display_line" | sed 's/[[:space:]]*$//')
        members=$(echo "$members" | tr -d '[:space:]')
        pid=$(echo "$display_line" | awk '{print $1}')
        if [[ -n "$pid" && -n "$display_line" ]]; then
            PROC_LIST+=("$display_line")
            GROUP_MEMBERS_MAP["$pid"]="$members"
        fi
    done < <(printf "%s\n" "$LIST" | grep -v '^[[:space:]]*$')

    if [ ${#PROC_LIST[@]} -eq 0 ]; then
        show_feedback "220" "No High Memory Processes" "All processes within normal limits" 1.5
        continue
    fi

    COLUMNS=$(printf "   %8s %10s %5s %7s    %-18s %s" "PID" "RAM" "TREND" "MEM %" "APP" "STATE")
    HEADER_TEXT=$(printf "\n   \033[1;33mTop 5 Memory Consumers:\033[0m\n\033[1;36m%s\033[0m" "$COLUMNS")
    NAV_HELP="\033[2;38;5;244m↑↓ navigate • enter submit • super+t %s • esc quit\033[0m"

    TARGET=""
    omaram_choose PROC_LIST "$HEADER_TEXT" "$NAV_HELP" TARGET "208" 0 "${LAST_SELECTED_INDEX:-0}" 1
    CHOOSE_STATUS=$?
    if [ "$CHOOSE_STATUS" -eq 200 ]; then
        continue
    elif [ "$CHOOSE_STATUS" -ne 0 ]; then
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
    if [[ "$NAME" =~ ^(java|python.*|node|electron|ruby|perl)$ ]]; then
        RESOLVED_CLASS=$(hyprctl clients -j 2>/dev/null | jq -r --argjson p "$PID" '.[] | select(.pid == $p) | .class' 2>/dev/null | head -1 || true)
        if [ -z "$RESOLVED_CLASS" ] && [[ -n "${GROUP_MEMBERS_MAP[$PID]:-}" ]]; then
            IFS=',' read -r -a _TMP_MEMS <<< "${GROUP_MEMBERS_MAP[$PID]}"
            for gp in "${_TMP_MEMS[@]}"; do
                RESOLVED_CLASS=$(hyprctl clients -j 2>/dev/null | jq -r --argjson p "$gp" '.[] | select(.pid == $p) | .class' 2>/dev/null | head -1 || true)
                [ -n "$RESOLVED_CLASS" ] && break
            done
        fi
        [ -n "$RESOLVED_CLASS" ] && NAME="$RESOLVED_CLASS"
    fi
    [[ -n $NAME && $NAME != "-" && $NAME != "." && $NAME != ".." ]] || NAME="process"
    NAME=$(printf '%s' "$NAME" | tr -cd '[:print:]')
    [ -z "$NAME" ] && NAME="process"

    ACTION_SEL_INDEX=0
    while true; do
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

        IFS=',' read -r -a GROUP_PIDS_ARRAY <<< "${GROUP_MEMBERS_MAP[$PID]:-$PID}"
        ACTIVE_GROUP_PIDS=()
        for gp in "${GROUP_PIDS_ARRAY[@]}"; do
            [[ -d "/proc/$gp" ]] && ACTIVE_GROUP_PIDS+=("$gp")
        done
        GROUP_COUNT=${#ACTIVE_GROUP_PIDS[@]}
        [ "$GROUP_COUNT" -eq 0 ] && GROUP_COUNT=1

        PROC_STATE=$(awk '/^State:/ {print $2}' "/proc/$PID/status" 2>/dev/null || echo "S")
        GROUP_HAS_PAUSED=0
        [[ "$PROC_STATE" =~ ^T ]] && GROUP_HAS_PAUSED=1
        for gp in "${ACTIVE_GROUP_PIDS[@]}"; do
            gp_state=$(awk '/^State:/ {print $2}' "/proc/$gp/status" 2>/dev/null || echo "S")
            if [[ "$gp_state" =~ ^T ]]; then
                GROUP_HAS_PAUSED=1
                break
            fi
        done

        clear
        gum style --foreground 51 --margin "1 0 0 5" "$LOGO"
        gum style --foreground 51 --margin "0 0 1 13" "The High Memory Guard & Diagnostic Tool"
        
        # Process Header Details: Selected process with True Reclaim (USS) and PSS
        HEADER_DETAILS="Selected: $NAME (PID $PID)"
        IS_NAPPING=0
        if [[ -f "$NAP_REGISTRY_FILE" ]] && grep -q "^${PID}:" "$NAP_REGISTRY_FILE" 2>/dev/null; then
            IS_NAPPING=1
            if [ "$GROUP_HAS_PAUSED" -eq 1 ]; then
                HEADER_DETAILS+=" 💤"
            else
                HEADER_DETAILS+=" ☀️"
            fi
            NAP_ACTION="☀️ Disable App Nap"
        else
            NAP_ACTION="💤 Enable App Nap"
        fi
        if [ "$USS_MB" -gt 0 ]; then
            HEADER_DETAILS=$(printf "%s\nTrue Reclaim (USS): %s MB • PSS: %s MB" "$HEADER_DETAILS" "$USS_MB" "$PSS_MB")
        fi
        gum style --border normal --border-foreground 196 --foreground 196 --width 45 --align center --margin "0 10" "$HEADER_DETAILS"

        if [ "$PROC_STATE" = "T" ]; then
            ACTION_HEADER=$(printf "\033[1;33mSelect Action \033[1;35m(Status: PAUSED)\033[0m:")
            TOGGLE_ACTION="▶️ Resume (SIGCONT)"
            AI_ACTION="🤖 Diagnose with AI (Inspect Paused)"
        else
            ACTION_HEADER=$(printf "\033[1;33mSelect Action \033[1;32m(Status: RUNNING)\033[0m:")
            TOGGLE_ACTION="⏸️ Pause (SIGSTOP)"
            AI_ACTION="🤖 Diagnose with AI (SIGSTOP)"
        fi

        if [ "$GROUP_COUNT" -gt 1 ]; then
            ACTION_ITEMS=(
                "💀 Kill Entire App ($GROUP_COUNT procs)"
                "🔄 Restart Entire App"
                "$NAP_ACTION"
                "$TOGGLE_ACTION"
                "🔍 Inspect Child Tabs ($GROUP_COUNT procs)"
                "$AI_ACTION"
                "🔙 Back to List"
            )
        else
            ACTION_ITEMS=(
                "💀 Kill Process"
                "🔄 Restart Process"
                "$NAP_ACTION"
                "$TOGGLE_ACTION"
                "$AI_ACTION"
                "🔙 Back to List"
            )
        fi
        ACTION_NAV="\033[2;38;5;244m↑↓ navigate • enter submit • super+t %s • esc back\033[0m"

        ACTION=""
        omaram_choose ACTION_ITEMS "$ACTION_HEADER" "$ACTION_NAV" ACTION "196" 10 "${ACTION_SEL_INDEX:-0}" 1
        ACTION_STATUS=$?
        if [ "$ACTION_STATUS" -eq 200 ]; then
            ACTION_SEL_INDEX="$LAST_SELECTED_INDEX"
            continue
        elif [ "$ACTION_STATUS" -ne 0 ]; then
            break
        fi
        ACTION_SEL_INDEX=0

    case "$ACTION" in
        *"Kill"*)
            [ -x "$NAP_SCRIPT" ] && "$NAP_SCRIPT" remove "$PID" 2>/dev/null || true
            mapfile -t CHILD_PIDS < <(pgrep -P "$PID" 2>/dev/null || true)
            kill -9 "$PID" "${CHILD_PIDS[@]}" "${ACTIVE_GROUP_PIDS[@]}" 2>/dev/null || true
            show_feedback "196" "💀 Killed $NAME" "All associated processes terminated"
            ;;
        *"Restart"*)
            [ -x "$NAP_SCRIPT" ] && "$NAP_SCRIPT" remove "$PID" 2>/dev/null || true
            # Security verification: Preserve sandbox boundaries and prevent sandbox escape.
            # A confined same-user application without host-execution permissions must not be executed on the host.
            if is_confined_or_sandboxed "$PID"; then
                local flatpak_app_id=""
                if [[ -f "/proc/$PID/root/.flatpak-info" ]]; then
                    flatpak_app_id=$(awk -F= '/^app-id=/ {print $2}' "/proc/$PID/root/.flatpak-info" 2>/dev/null || true)
                fi

                if [[ -n "$flatpak_app_id" && "$flatpak_app_id" =~ ^[a-zA-Z0-9._-]+$ ]] && command -v flatpak >/dev/null 2>&1; then
                    mapfile -t CHILD_PIDS < <(pgrep -P "$PID" 2>/dev/null || true)
                    kill -9 "$PID" "${CHILD_PIDS[@]}" "${ACTIVE_GROUP_PIDS[@]}" 2>/dev/null || true
                    sleep 0.5
                    (cd "$HOME" && flatpak run "$flatpak_app_id" </dev/null >/dev/null 2>&1 & disown)
                    show_feedback "46" "🔄 Restarted $NAME" "Via Flatpak sandbox launcher"
                else
                    # For all other confined processes (containers, namespaces, bwrap, custom sandboxes),
                    # skip host restart to preserve the sandbox boundary and prevent host code execution.
                    show_feedback "220" "⚠️ $NAME is in a sandbox" "Host restart skipped; use app launcher"
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
                show_feedback "196" "❌ Cannot restart $NAME" "Binary missing or not executable" 2
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
                show_feedback "196" "❌ Cannot restart $NAME" "inline interpreter code rejected" 2
                continue
            fi

            mapfile -t CHILD_PIDS < <(pgrep -P "$PID" 2>/dev/null || true)
            kill -9 "$PID" "${CHILD_PIDS[@]}" "${ACTIVE_GROUP_PIDS[@]}" 2>/dev/null || true
            sleep 0.5
            (cd "$CWD" && "${CMD_ARGS[@]}" </dev/null >/dev/null 2>&1 & disown)
            show_feedback "46" "🔄 Restarted $NAME cleanly" "Fresh instance launched" 1.5
            ;;
        *"Inspect"*)
            while true; do
                clear
                gum style --foreground 51 --margin "1 0 0 5" "$LOGO"
                gum style --foreground 51 --margin "0 0 1 13" "The High Memory Guard & Diagnostic Tool"

                CHILD_DATA=()
                for cpid in "${ACTIVE_GROUP_PIDS[@]}"; do
                    if [[ -d "/proc/$cpid" ]]; then
                        c_rss_kb=$(awk '/^VmRSS:/ {print $2}' "/proc/$cpid/status" 2>/dev/null || echo "0")
                        c_rss_mb=$(( c_rss_kb / 1024 ))
                        c_state=$(awk '/^State:/ {print $2}' "/proc/$cpid/status" 2>/dev/null || echo "S")
                        c_tag=""
                        [[ "$c_state" =~ ^T ]] && c_tag=" ⏸️"
                        c_role="child"
                        [[ "$cpid" == "$PID" ]] && c_role="root"

                        c_comm=$(cat "/proc/$cpid/comm" 2>/dev/null || echo "")
                        c_cmd=$(tr '\0' ' ' < "/proc/$cpid/cmdline" 2>/dev/null || echo "")
                        c_type=""
                        if [[ "$c_cmd" =~ --type=([a-zA-Z0-9_-]+) ]]; then
                            c_type="${BASH_REMATCH[1]}"
                        elif [[ "$cpid" == "$PID" ]]; then
                            c_type="main"
                        elif [[ -n "$c_comm" && "$c_comm" != "$NAME" ]]; then
                            c_type="$c_comm"
                        else
                            c_type="worker"
                        fi

                        CHILD_DATA+=("${c_rss_mb}|${cpid}|${c_role}|${c_type}|${c_tag}")
                    fi
                done

                if [ ${#CHILD_DATA[@]} -eq 0 ]; then
                    show_feedback "220" "No Child Processes" "No active child processes remaining" 1.5
                    break
                fi

                mapfile -t SORTED_CHILDREN < <(printf "%s\n" "${CHILD_DATA[@]}" | sort -t'|' -k1 -n -r)
                ACTIVE_COUNT=${#SORTED_CHILDREN[@]}

                SUB_TITLE="Inspecting $NAME (Root PID $PID) • $ACTIVE_COUNT procs"
                if [ "$ACTIVE_COUNT" -gt 5 ]; then
                    SUB_TITLE+=" (Top 5)"
                fi
                gum style --foreground 51 --align center --margin "0 0 1 0" "$SUB_TITLE"

                CHILD_COLUMNS=$(printf "   %8s %8s   %-6s  %-12s" "PID" "RAM" "ROLE" "TYPE")
                CHILD_HEADER=$(printf "\033[1;33mSelect Child Process to Manage:\033[0m\n\033[1;36m%s\033[0m" "$CHILD_COLUMNS")
                CHILD_NAV="\033[2;38;5;244m↑↓ navigate • enter select • esc back\033[0m"

                CHILD_CHOICES=()
                DISPLAY_CHILDREN=("${SORTED_CHILDREN[@]:0:5}")
                for item in "${DISPLAY_CHILDREN[@]}"; do
                    IFS='|' read -r c_mb c_pid c_role c_type c_tag <<< "$item"
                    CHILD_CHOICES+=("$(printf "%8s %5d MB   %-6s  %-12s%s" "$c_pid" "$c_mb" "$c_role" "$c_type" "$c_tag")")
                done
                CHILD_CHOICES+=("🔙 Back to App Menu")

                SELECTED_CHILD=""
                if ! omaram_choose CHILD_CHOICES "$CHILD_HEADER" "$CHILD_NAV" SELECTED_CHILD "51" 4; then
                    break
                fi

                if [[ -z "$SELECTED_CHILD" || "$SELECTED_CHILD" == *"Back"* ]]; then
                    break
                fi

                SELECTED_CPID=$(echo "$SELECTED_CHILD" | awk '{print $1}')
                if [[ ! "$SELECTED_CPID" =~ ^[0-9]+$ ]] || [[ ! -d "/proc/$SELECTED_CPID" ]]; then
                    continue
                fi

                CP_STATE=$(awk '/^State:/ {print $2}' "/proc/$SELECTED_CPID/status" 2>/dev/null || echo "S")
                if [ "$CP_STATE" = "T" ]; then
                    CP_TOGGLE="▶️ Resume Child (SIGCONT)"
                else
                    CP_TOGGLE="⏸️ Pause Child (SIGSTOP)"
                fi

                CP_ACTION_HEADER=$(printf "\n\033[1;33mManage Child PID %s \033[1;36m(%s)\033[0m:" "$SELECTED_CPID" "$NAME")
                CP_ACTIONS=(
                    "💀 Kill Child Process"
                    "$CP_TOGGLE"
                    "🔙 Back to Process List"
                )

                CP_ACTION=""
                if ! omaram_choose CP_ACTIONS "$CP_ACTION_HEADER" "$CHILD_NAV" CP_ACTION "196" 10; then
                    continue
                fi

                case "$CP_ACTION" in
                    *"Kill"*)
                        kill -9 "$SELECTED_CPID" 2>/dev/null || true
                        show_feedback "196" "💀 Terminated Child PID $SELECTED_CPID" "Child process terminated" 1.2
                        ;;
                    *"Pause"*)
                        kill -STOP "$SELECTED_CPID" 2>/dev/null || true
                        show_feedback "220" "⏸️ Paused Child PID $SELECTED_CPID" "Child execution suspended (SIGSTOP)" 1.2
                        ;;
                    *"Resume"*)
                        kill -CONT "$SELECTED_CPID" 2>/dev/null || true
                        show_feedback "46" "▶️ Resumed Child PID $SELECTED_CPID" "Child execution resumed (SIGCONT)" 1.2
                        ;;
                    *)
                        ;;
                esac
            done
            ;;
        *"App Nap"*)
            if [ "$IS_NAPPING" -eq 1 ]; then
                [ -x "$NAP_SCRIPT" ] && "$NAP_SCRIPT" remove "$PID" 2>/dev/null || true
                show_feedback "46" "☀️ App Nap Disabled: $NAME" "Application running normally" 1.2
            else
                local win_class=""
                win_class=$(hyprctl clients -j 2>/dev/null | jq -r --argjson p "$PID" '.[] | select(.pid == $p) | .class' 2>/dev/null | head -1 || true)
                [ -z "$win_class" ] && win_class="$NAME"
                local member_str
                member_str=$(IFS=,; echo "${ACTIVE_GROUP_PIDS[*]}")
                [ -x "$NAP_SCRIPT" ] && "$NAP_SCRIPT" add "$PID" "$win_class" "$member_str" 2>/dev/null || true
                [ -x "$NAP_SCRIPT" ] && "$NAP_SCRIPT" sync 2>/dev/null || true
                show_feedback "51" "💤 App Nap Enabled: $NAME" "Auto-sleeps on unfocus • Wakes on focus" 1.2
            fi
            ;;
        *"Diagnose"*)
            tile_if_floating
            SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
            "$SCRIPT_DIR/omaram-diagnose.sh" "$PID" >/dev/null 2>&1 &
            show_feedback "51" "🤖 AI Diagnostics Launched" "Process paused & inspector attached" 2.5
            ;;
        *"Pause"*)
            mapfile -t CHILD_PIDS < <(pgrep -P "$PID" 2>/dev/null || true)
            kill -STOP "$PID" "${CHILD_PIDS[@]}" "${ACTIVE_GROUP_PIDS[@]}" 2>/dev/null || true
            show_feedback "220" "⏸️ Paused $NAME" "Execution suspended (SIGSTOP)" 1.5
            ;;
        *"Resume"*)
            mapfile -t CHILD_PIDS < <(pgrep -P "$PID" 2>/dev/null || true)
            kill -CONT "$PID" "${CHILD_PIDS[@]}" "${ACTIVE_GROUP_PIDS[@]}" 2>/dev/null || true
            show_feedback "46" "▶️ Resumed $NAME" "Execution resumed (SIGCONT)" 1.5
            ;;
        *)
            break
            ;;
    esac
    break
done
done
