#!/bin/bash
while true; do
    clear
    echo -e "\033[1;31m=== High Memory Guard ===\033[0m\n"

    echo "Current Memory Usage:"
    free -h | head -n 2

    echo -e "\n\033[1;33mTop 5 Memory Consumers:\033[0m"
    ps -U "$USER" -o pid,rss,comm --sort=-rss | head -n 6 | awk 'NR==1 {print "PID\tRAM (MB)\tCOMMAND"} NR>1 {printf "%s\t%s MB\t%s\n", $1, int($2/1024), $3}'

    echo -e "\nSelect a process to manage:"
    LIST=$(ps -U "$USER" -o pid,rss,comm --sort=-rss | head -n 6 | tail -n 5 | awk '{printf "%s (%s MB) - %s\n", $1, int($2/1024), $3}')

    TARGET=$(echo "$LIST" | gum choose --header="Choose process (ESC to quit):" --height=8)

    if [ -z "$TARGET" ]; then
        exit 0
    fi

    PID=$(echo "$TARGET" | awk '{print $1}')
    NAME=$(echo "$TARGET" | awk '{print $5}')

    printf "\nSelected: \033[1;32m%s (PID %s)\033[0m\n" "$NAME" "$PID"
    ACTION=$(gum choose "💀 Kill Process" "⏸️ Pause (SIGSTOP)" "▶️ Resume (SIGCONT)" "🔙 Back to List")

    case "$ACTION" in
        *"Kill"*)
            kill -9 "$PID"
            echo "Killed $NAME."
            sleep 2
            ;;
        *"Pause"*)
            kill -STOP "$PID"
            echo "Paused $NAME. Memory is retained but it can't execute."
            sleep 2
            ;;
        *"Resume"*)
            kill -CONT "$PID"
            echo "Resumed $NAME."
            sleep 2
            ;;
        *)
            continue
            ;;
    esac
done
