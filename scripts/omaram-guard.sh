#!/bin/bash

# Request snug terminal resize (if supported)
printf '\033[8;25;65t'

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

    gum style --foreground 51 --margin "1 0 0 2" "$LOGO"
    gum style --foreground 245 --margin "0 0 1 2" "The High Memory Guard & Diagnostic Tool"

    # Memory Stats Box
    # Using awk to cleanly strip 'Mem:' and perfectly align the columns
    MEM_STATS=$(free -h | head -n 2 | awk 'NR==1 {print "Total\tUsed\tFree\tShared\tCache\tAvail"} NR==2 {print $2"\t"$3"\t"$4"\t"$5"\t"$6"\t"$7}' | column -t -s $'\t')
    gum style --border rounded --border-foreground 99 --padding "0 2" --margin "0 2" "$MEM_STATS"
    
    # Process List
    LIST=$(ps -U "$USER" -o pid,rss,comm --sort=-rss | head -n 6 | tail -n 5 | awk '{printf "%-8s %-10s %s\n", $1, int($2/1024)" MB", $3}')

    HEADER_TEXT=$(printf "\033[1;33mTop 5 Memory Consumers:\033[0m\n\033[2mSelect an app to manage (ESC to quit)\033[0m")
    
    # We use margin to indent the entire gum choose block so it aligns with the logo and box
    # Oh wait! gum choose doesn't have margin! 
    # But it is naturally left-aligned, which perfectly matches our margin "0 2" above!
    TARGET=$(echo "$LIST" | gum choose --cursor="ᐅ " --header="$HEADER_TEXT" --height=8)

    if [ -z "$TARGET" ]; then
        exit 130
    fi

    PID=$(echo "$TARGET" | awk '{print $1}')
    NAME=$(echo "$TARGET" | awk '{print $4}')

    clear
    gum style --foreground 51 --margin "1 0 0 2" "$LOGO"
    
    ACTION_BOX=$(gum style --border normal --border-foreground 212 --padding "1 3" "Selected Process: $NAME (PID $PID)")
    gum style --margin "1 2" "$ACTION_BOX"

    ACTION_HEADER=$(printf "\033[1;33mSelect Action:\033[0m")
    ACTION=$(gum choose --cursor="ᐅ " --header="$ACTION_HEADER" "💀 Kill Process" "⏸️ Pause (SIGSTOP)" "▶️ Resume (SIGCONT)" "🔙 Back to List")

    case "$ACTION" in
        *"Kill"*)
            kill -9 "$PID" 2>/dev/null
            gum style --foreground 196 --margin "1 2" "💀 Killed $NAME."
            sleep 1.5
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
