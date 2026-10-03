#!/bin/bash

# Request snug terminal resize
printf '\033[8;25;85t'

LOGO=$(cat << 'ASCII'
  ██████╗ ███╗   ███╗ █████╗ ██████╗  █████╗ ███╗   ███╗
 ██╔═══██╗████╗ ████║██╔══██╗██╔══██╗██╔══██╗████╗ ████║
 ██║   ██║██╔████╔██║███████║██████╔╝███████║██╔████╔██║
 ██║   ██║██║╚██╔╝██║██╔══██║██╔══██╗██╔══██║██║╚██╔╝██║
 ╚██████╔╝██║ ╚═╝ ██║██║  ██║██║  ██║██║  ██║██║ ╚═╝ ██║
  ╚═════╝ ╚═╝     ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝     ╚═╝
ASCII
)

# Zero Width Space character to prevent gum choose from trimming our padding
ZWS=$(printf '\xE2\x80\x8B')

while true; do
    clear

    gum style --foreground 51 --align center --margin "1 0 0 0" "$LOGO"
    gum style --foreground 245 --align center "The High Memory Guard & Diagnostic Tool"

    MEM_STATS=$(free -h | head -n 2 | sed 's/Mem:/    /')
    MEM_BOX=$(gum style --border rounded --border-foreground 99 --padding "0 2" "$MEM_STATS")
    gum style --align center --margin "1 0" "$MEM_BOX"
    
    # Calculate padding for centering
    COLS=$(tput cols || echo 80)
    MENU_WIDTH=45
    PAD_LEN=$(( (COLS - MENU_WIDTH) / 2 ))
    [ $PAD_LEN -lt 0 ] && PAD_LEN=0
    PAD=$(printf '%*s' "$PAD_LEN" '')

    # Prepare list (No redundant echo this time!)
    # We append the ZWS right at the start to anchor the line
    LIST=$(ps -U "$USER" -o pid,rss,comm --sort=-rss | head -n 6 | tail -n 5 | awk -v pad="${ZWS}${PAD}" '{printf "%s%-8s %-10s %s\n", pad, $1, int($2/1024)" MB", $3}')

    HEADER_TEXT=$(printf "%s\033[1;33mTop 5 Memory Consumers:\033[0m\n%s\033[2mSelect an app to manage (ESC to quit)\033[0m" "${PAD}" "${PAD}")
    
    TARGET=$(echo "$LIST" | gum choose --cursor="ᐅ " --header="$HEADER_TEXT" --height=8)

    if [ -z "$TARGET" ]; then
        exit 0
    fi

    # Awk strips out the ZWS and leading spaces naturally
    PID=$(echo "$TARGET" | awk '{print $1}')
    NAME=$(echo "$TARGET" | awk '{print $4}')

    clear
    gum style --foreground 51 --align center --margin "1 0 0 0" "$LOGO"
    
    ACTION_BOX=$(gum style --border normal --border-foreground 212 --padding "1 3" "Selected Process: $NAME (PID $PID)")
    gum style --align center --margin "1 0" "$ACTION_BOX"

    ACTION_LIST=$(printf "%s%s💀 Kill Process\n%s%s⏸️ Pause (SIGSTOP)\n%s%s▶️ Resume (SIGCONT)\n%s%s🔙 Back to List" "$ZWS" "$PAD" "$ZWS" "$PAD" "$ZWS" "$PAD" "$ZWS" "$PAD")
    ACTION_HEADER=$(printf "%s\033[1;33mSelect Action:\033[0m" "${PAD}")

    ACTION=$(echo "$ACTION_LIST" | gum choose --cursor="ᐅ " --header="$ACTION_HEADER")

    case "$ACTION" in
        *"Kill"*)
            kill -9 "$PID" 2>/dev/null
            gum style --foreground 196 --align center --margin "1 0" "💀 Killed $NAME."
            sleep 1.5
            ;;
        *"Pause"*)
            kill -STOP "$PID" 2>/dev/null
            gum style --foreground 220 --align center --margin "1 0" "⏸️ Paused $NAME. Execution suspended."
            sleep 2
            ;;
        *"Resume"*)
            kill -CONT "$PID" 2>/dev/null
            gum style --foreground 46 --align center --margin "1 0" "▶️ Resumed $NAME."
            sleep 1.5
            ;;
        *)
            continue
            ;;
    esac
done
