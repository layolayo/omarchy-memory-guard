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

    # Memory Stats Box
    # Using awk to cleanly strip 'Mem:' and perfectly align the columns
    MEM_STATS=$(free -h | head -n 2 | awk 'NR==1 {print "Total\tUsed\tFree\tShared\tCache\tAvail"} NR==2 {print $2"\t"$3"\t"$4"\t"$5"\t"$6"\t"$7}' | sed 's/Gi/G/g; s/Mi/M/g' | column -t -s $'\t' -R 1,2,3,4,5,6)
    MEM_STATS=$(echo "$MEM_STATS" | sed $'s/.*/\033[38;5;135m&\033[0m/')
    MEM_BOX=$(gum style --border rounded --padding "0 2" "$MEM_STATS")
    MEM_BOX=$(echo "$MEM_BOX" | sed $'s/.*/\033[38;5;135m&\033[0m/')
    gum style --margin "0 7" "$MEM_BOX"
    
    # Process List: Strictly filter by UID, exclude self, parent, and terminal wrappers
    LIST=$(ps -u "$UID" --no-headers -o pid,rss,pmem,state,comm --sort=-rss 2>/dev/null | awk -v self="$$" -v parent="$PPID" '
        $1 != self && $1 != parent && $5 !~ /^(omaram|gum|bash|ps|xdg-terminal)/ {
            tag = ($4 ~ /^T/ ? " ⏸️ PAUSED" : "");
            printf "%8s %7s MB %6s%%    %s%s\n", $1, int($2/1024), $3, $5, tag
        }' | head -n 5)

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

    clear
    gum style --foreground 51 --margin "1 0 0 2" "$LOGO"
    gum style --foreground 51 --margin "0 0 1 10" "The High Memory Guard & Diagnostic Tool"
    
    # Match the width of MEM_BOX (45 chars) and perfectly center it under the logo
    gum style --border normal --border-foreground 196 --foreground 196 --width 43 --align center --margin "1 7" "Selected Process: $NAME (PID $PID)"

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
            kill -9 "$PID" 2>/dev/null || true
            gum style --foreground 196 --margin "1 2" "💀 Killed $NAME."
            sleep 1.5
            ;;
        *"Restart"*)
            CWD=$(readlink -f "/proc/$PID/cwd" 2>/dev/null || echo "$HOME")
            if [[ ! -d "$CWD" ]]; then
                CWD="$HOME"
            fi
            EXE=$(readlink -f "/proc/$PID/exe" 2>/dev/null || true)
            mapfile -d '' CMD_ARGS < "/proc/$PID/cmdline" 2>/dev/null || true
            if [ ${#CMD_ARGS[@]} -eq 0 ]; then
                if [[ -n "$EXE" && -x "$EXE" ]]; then
                    CMD_ARGS=("$EXE")
                else
                    CMD_ARGS=("$NAME")
                fi
            fi
            kill -9 "$PID" 2>/dev/null || true
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
            kill -STOP "$PID" 2>/dev/null || true
            gum style --foreground 220 --margin "1 2" "⏸️ Paused $NAME. Execution suspended."
            sleep 2
            ;;
        *"Resume"*)
            kill -CONT "$PID" 2>/dev/null || true
            gum style --foreground 46 --margin "1 2" "▶️ Resumed $NAME."
            sleep 1.5
            ;;
        *)
            continue
            ;;
    esac
done
