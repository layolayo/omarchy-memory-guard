#!/bin/bash

# Request terminal resize to a snug 28x85 (Hyprland may ignore this depending on window rules, but Alacritty/Foot support it)
printf '\033[8;28;85t'

LOGO=$(cat << 'ASCII'
  ██████╗ ███╗   ███╗ █████╗ ██████╗  █████╗ ███╗   ███╗
 ██╔═══██╗████╗ ████║██╔══██╗██╔══██╗██╔══██╗████╗ ████║
 ██║   ██║██╔████╔██║███████║██████╔╝███████║██╔████╔██║
 ██║   ██║██║╚██╔╝██║██╔══██║██╔══██╗██╔══██║██║╚██╔╝██║
 ╚██████╔╝██║ ╚═╝ ██║██║  ██║██║  ██║██║  ██║██║ ╚═╝ ██║
  ╚═════╝ ╚═╝     ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝     ╚═╝
ASCII
)

while true; do
    clear

    # Render Centered Logo
    gum style --foreground 51 --align center --margin "1 0 0 0" "$LOGO"
    gum style --foreground 245 --align center "The High Memory Guard & Diagnostic Tool"

    # Render Memory Stats in a beautiful centered box
    MEM_STATS=$(free -h | head -n 2)
    MEM_BOX=$(gum style --border rounded --border-foreground 99 --padding "0 2" "$MEM_STATS")
    gum style --align center --margin "1 0" "$MEM_BOX"

    # Top Consumers
    gum style --foreground 220 --bold "  Top 5 Memory Consumers:"
    ps -U "$USER" -o pid,rss,comm --sort=-rss | head -n 6 | awk 'NR==1 {print "    PID\tRAM (MB)\tCOMMAND"} NR>1 {printf "    %s\t%s MB\t%s\n", $1, int($2/1024), $3}'
    
    echo ""
    LIST=$(ps -U "$USER" -o pid,rss,comm --sort=-rss | head -n 6 | tail -n 5 | awk '{printf "%s (%s MB) - %s\n", $1, int($2/1024), $3}')

    # Selection Menu
    TARGET=$(echo "$LIST" | gum choose --cursor="ᐅ " --header="  Select a process to manage (ESC to quit):" --height=8)

    if [ -z "$TARGET" ]; then
        exit 0
    fi

    PID=$(echo "$TARGET" | awk '{print $1}')
    NAME=$(echo "$TARGET" | awk '{print $5}')

    # Action Menu
    clear
    gum style --foreground 51 --align center --margin "1 0 0 0" "$LOGO"
    
    ACTION_BOX=$(gum style --border normal --border-foreground 212 --padding "1 3" "Selected Process: $NAME (PID $PID)")
    gum style --align center --margin "1 0" "$ACTION_BOX"

    ACTION=$(gum choose --cursor="ᐅ " "💀 Kill Process" "⏸️ Pause (SIGSTOP)" "▶️ Resume (SIGCONT)" "🔙 Back to List")

    case "$ACTION" in
        *"Kill"*)
            kill -9 "$PID" 2>/dev/null
            gum style --foreground 196 --margin "1 2" "💀 Killed $NAME."
            sleep 1.5
            ;;
        *"Pause"*)
            kill -STOP "$PID" 2>/dev/null
            gum style --foreground 220 --margin "1 2" "⏸️ Paused $NAME. Memory is retained but execution is suspended."
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
