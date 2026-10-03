#!/bin/bash

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
    
    # Process List
    LIST=$(ps -U "$USER" -o pid,rss,pmem,state,comm --sort=-rss | head -n 6 | tail -n 5 | awk '{
        tag = ($4 ~ /^T/ ? " ⏸️ PAUSED" : "");
        printf "%8s %7s MB %6s%%    %s%s\n", $1, int($2/1024), $3, $5, tag
    }')

    BBLANK=$(printf '\xE2\xA0\x80')
    LIST=$(echo "$LIST" | sed "s/^/$BBLANK/g")
    COLUMNS=$(printf "%s  %8s %10s %7s    %s" "$BBLANK" "PID" "RAM" "MEM %" "APP")
    HEADER_TEXT=$(printf "\033[1;33mTop 5 Memory Consumers:\033[0m\n\033[2m[ Super + T: Tile  •  ESC: Quit ]\033[0m\n\033[1;36m%s\033[0m" "$COLUMNS")

    TARGET=$(echo "$LIST" | gum choose --cursor="ᐅ " --cursor.foreground="196" --selected.foreground="196" --header="$HEADER_TEXT" --height=7)

    if [ -z "$TARGET" ]; then
        exit 130
    fi

    # Strip the Braille Blank hack before extracting values
    TARGET=$(echo "$TARGET" | sed "s/$BBLANK//g")

    PID=$(echo "$TARGET" | awk '{print $1}')
    NAME=$(echo "$TARGET" | awk '{print $5}')

    clear
    gum style --foreground 51 --margin "1 0 0 2" "$LOGO"
    gum style --foreground 51 --margin "0 0 1 10" "The High Memory Guard & Diagnostic Tool"
    
    # Match the width of MEM_BOX (45 chars) and perfectly center it under the logo
    gum style --border normal --border-foreground 196 --foreground 196 --width 43 --align center --margin "1 7" "Selected Process: $NAME (PID $PID)"

    PROC_STATE=$(awk '/^State:/ {print $2}' "/proc/$PID/status" 2>/dev/null || echo "S")

    if [ "$PROC_STATE" = "T" ]; then
        ACTION_HEADER=$(printf "\033[1;33mSelect Action \033[1;35m(Status: PAUSED)\033[0m:\n\033[2m[ Super + T: Tile  •  ESC: Back ]\033[0m")
        TOGGLE_ACTION="▶️ Resume (SIGCONT)"
        AI_ACTION="🤖 Diagnose with AI (Inspect Paused)"
    else
        ACTION_HEADER=$(printf "\033[1;33mSelect Action \033[1;32m(Status: RUNNING)\033[0m:\n\033[2m[ Super + T: Tile  •  ESC: Back ]\033[0m")
        TOGGLE_ACTION="⏸️ Pause (SIGSTOP)"
        AI_ACTION="🤖 Diagnose with AI (SIGSTOP)"
    fi

    ACTION=$(gum choose --cursor="ᐅ " --cursor.foreground="196" --selected.foreground="196" --header="$ACTION_HEADER" \
        "💀 Kill Process" \
        "🔄 Restart Process" \
        "$TOGGLE_ACTION" \
        "$AI_ACTION" \
        "🔙 Back to List")

    case "$ACTION" in
        *"Kill"*)
            kill -9 "$PID" 2>/dev/null
            gum style --foreground 196 --margin "1 2" "💀 Killed $NAME."
            sleep 1.5
            ;;
        *"Restart"*)
            CWD=$(readlink -f "/proc/$PID/cwd" 2>/dev/null || echo "$HOME")
            mapfile -d '' CMD_ARGS < "/proc/$PID/cmdline" 2>/dev/null || true
            if [ ${#CMD_ARGS[@]} -eq 0 ]; then
                CMD_ARGS=("$NAME")
            fi
            kill -9 "$PID" 2>/dev/null
            sleep 0.5
            (cd "$CWD" && "${CMD_ARGS[@]}" >/dev/null 2>&1 & disown)
            gum style --foreground 46 --margin "1 2" "🔄 Restarted $NAME cleanly."
            sleep 1.5
            ;;
        *"Diagnose"*)
            SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
            "$SCRIPT_DIR/omaram-diagnose.sh" "$PID" >/dev/null 2>&1 &
            gum style --foreground 51 --margin "1 2" "⏸️ Paused $NAME & launched AI diagnostic agent."
            sleep 2.5
            ;;
        *"Pause"*)
            kill -STOP "$PID" 2>/dev/null
            gum style --foreground 220 --margin "1 2" "⏸️ Paused $NAME. Execution suspended."
            sleep 2
            ;;
        *"Resume"*)
            kill -CONT "$PID" 2>/dev/null
            gum style --foreground 46 --margin "1 2" "▶️ Resumed $NAME."
            sleep 1.5
            ;;
        *)
            continue
            ;;
    esac
done
