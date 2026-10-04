#!/bin/bash
# OMARAM Guard - Smart App Nap Watcher
# Transparently suspends unfocused background applications (SIGSTOP)
# and wakes them on focus (SIGCONT) via Hyprland IPC socket.

set -euo pipefail

REGISTRY_DIR="${XDG_RUNTIME_DIR:-/run/user/$UID}/omaram"
mkdir -p -m 0700 "$REGISTRY_DIR" 2>/dev/null || true
REGISTRY_FILE="$REGISTRY_DIR/nap.registry"
PID_FILE="$REGISTRY_DIR/nap-watcher.pid"

# Ensure registry exists with safe 0600 permissions
touch "$REGISTRY_FILE"
chmod 0600 "$REGISTRY_FILE" 2>/dev/null || true

# Helper to validate target PID belongs to current UID and is safe
validate_pid() {
    local pid="$1"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    [ "$pid" -le 1 ] && return 1
    [ "$pid" -eq "$$" ] && return 1
    [ "$pid" -eq "$PPID" ] && return 1
    [[ -d "/proc/$pid" ]] || return 1

    local p_uid
    p_uid=$(stat -c '%u' "/proc/$pid" 2>/dev/null || echo "")
    [ "$p_uid" = "$UID" ] || return 1

    local comm
    comm=$(cat "/proc/$pid/comm" 2>/dev/null || echo "")
    case "$comm" in
        Hyprland|hyprland|waybar|omarchy-shell|systemd|bash|sh|zsh|xdg-terminal-exec|gum)
            return 1
            ;;
    esac
    return 0
}

cmd_add() {
    local pid="$1"
    local class="${2:-}"
    local members="${3:-$pid}"

    if ! validate_pid "$pid"; then
        echo "Error: Invalid or restricted PID $pid" >&2
        return 1
    fi

    if [ -z "$class" ]; then
        class=$(hyprctl clients -j 2>/dev/null | jq -r --argjson p "$pid" '.[] | select(.pid == $p) | .class' 2>/dev/null | head -1 || true)
        [ -z "$class" ] && class=$(cat "/proc/$pid/comm" 2>/dev/null || echo "app")
    fi

    # Sanitize inputs
    class=$(printf '%s' "$class" | tr -cd '[:alnum:]_.-')
    members=$(printf '%s' "$members" | tr -cd '[:digit:],')

    # Remove previous entry for this PID if exists
    if [ -f "$REGISTRY_FILE" ]; then
        sed -i "/^${pid}:/d" "$REGISTRY_FILE"
    fi

    echo "${pid}:${class}:${members}" >> "$REGISTRY_FILE"
    cmd_ensure_running
}

cmd_remove() {
    local pid="$1"
    local members=""

    if [ -f "$REGISTRY_FILE" ]; then
        local line
        line=$(grep "^${pid}:" "$REGISTRY_FILE" 2>/dev/null || true)
        if [ -n "$line" ]; then
            IFS=':' read -r _ _ members <<< "$line"
        fi
        sed -i "/^${pid}:/d" "$REGISTRY_FILE"
    fi

    # Resume app immediately upon removal from App Nap
    IFS=',' read -r -a pids_to_wake <<< "${members:-$pid}"
    kill -CONT "${pids_to_wake[@]}" 2>/dev/null || true

    # If registry is now empty, stop watcher
    if [ ! -s "$REGISTRY_FILE" ]; then
        cmd_stop
    fi
}

cmd_is_napping() {
    local pid="$1"
    [ -f "$REGISTRY_FILE" ] || return 2
    grep -q "^${pid}:" "$REGISTRY_FILE" || return 2

    # If in registry, check process state
    local state
    state=$(awk '/^State:/ {print $2}' "/proc/$pid/status" 2>/dev/null || echo "S")
    if [[ "$state" =~ ^T ]]; then
        return 0 # Sleeping (napping)
    else
        return 1 # Awake & active
    fi
}

cmd_list() {
    if [ -f "$REGISTRY_FILE" ]; then
        cat "$REGISTRY_FILE"
    fi
}

cmd_stop() {
    if [ -f "$PID_FILE" ]; then
        local wpid
        wpid=$(cat "$PID_FILE" 2>/dev/null || true)
        if [[ -n "$wpid" && "$wpid" =~ ^[0-9]+$ ]]; then
            kill "$wpid" 2>/dev/null || true
        fi
        rm -f "$PID_FILE"
    fi
}

cmd_ensure_running() {
    if [ -f "$PID_FILE" ]; then
        local wpid
        wpid=$(cat "$PID_FILE" 2>/dev/null || true)
        if [[ -n "$wpid" && "$wpid" =~ ^[0-9]+$ ]] && kill -0 "$wpid" 2>/dev/null; then
            return 0
        fi
    fi

    # Start watcher in background
    local script_path
    script_path=$(readlink -f "${BASH_SOURCE[0]}")
    (setsid "$script_path" watch >/dev/null 2>&1 &)
}

cmd_watch() {
    # Single-instance enforcement
    if [ -f "$PID_FILE" ]; then
        local old_pid
        old_pid=$(cat "$PID_FILE" 2>/dev/null || true)
        if [[ -n "$old_pid" && "$old_pid" =~ ^[0-9]+$ ]] && kill -0 "$old_pid" 2>/dev/null; then
            exit 0
        fi
    fi

    echo "$$" > "$PID_FILE"
    trap 'rm -f "$PID_FILE"; exit 0' EXIT TERM INT

    local sock="${XDG_RUNTIME_DIR:-/run/user/$UID}/hypr/${HYPRLAND_INSTANCE_SIGNATURE:-}/.socket2.sock"
    if [ ! -S "$sock" ]; then
        exit 0
    fi

    # Background event loop reading Hyprland's socket2
    # Privacy invariant: window titles are immediately discarded in memory
    socat - "UNIX-CONNECT:$sock" 2>/dev/null | while read -r raw_event; do
        # Only act on window focus changes
        case "$raw_event" in
            "activewindow>>"*|"activewindowv2>>"*)
                # Exit if registry no longer exists or is empty
                if [ ! -s "$REGISTRY_FILE" ]; then
                    exit 0
                fi

                # Title Discard: Immediately strip title, keeping only class
                local active_class=""
                if [[ "$raw_event" =~ ^activewindow\>\> ]]; then
                    active_class="${raw_event#activewindow>>}"
                    active_class="${active_class%%,*}" # Title immediately stripped and dropped
                fi

                local active_pid=""
                active_pid=$(hyprctl activewindow -j 2>/dev/null | jq -r '.pid // empty' 2>/dev/null || true)

                # Read active nap entries and synchronize states
                local line r_pid r_class r_members
                while IFS=':' read -r r_pid r_class r_members; do
                    [[ -n "$r_pid" ]] || continue

                    # Auto-prune dead processes
                    if [[ ! -d "/proc/$r_pid" ]]; then
                        sed -i "/^${r_pid}:/d" "$REGISTRY_FILE"
                        continue
                    fi

                    IFS=',' read -r -a mem_array <<< "${r_members:-$r_pid}"

                    # Determine if registered app has user focus
                    local is_focused=0
                    if [[ -n "$active_pid" ]]; then
                        for mp in "${mem_array[@]}"; do
                            if [ "$mp" = "$active_pid" ]; then
                                is_focused=1
                                break
                            fi
                        done
                    fi

                    if [ "$is_focused" -eq 0 ] && [[ -n "$active_class" && -n "$r_class" && "${active_class,,}" = "${r_class,,}" ]]; then
                        is_focused=1
                    fi

                    if [ "$is_focused" -eq 1 ]; then
                        # WAKE: Instant SIGCONT to root and all member processes
                        kill -CONT "${mem_array[@]}" 2>/dev/null || true
                    else
                        # SLEEP: Suspend unfocused process
                        kill -STOP "${mem_array[@]}" 2>/dev/null || true
                    fi
                done < "$REGISTRY_FILE"
                ;;
        esac
    done
}

case "${1:-}" in
    add)
        shift
        cmd_add "$@"
        ;;
    remove)
        shift
        cmd_remove "$@"
        ;;
    is-napping)
        shift
        cmd_is_napping "$@"
        ;;
    list)
        cmd_list
        ;;
    stop)
        cmd_stop
        ;;
    ensure-running)
        cmd_ensure_running
        ;;
    watch)
        cmd_watch
        ;;
    *)
        echo "Usage: $0 {add <pid> [class] [members]|remove <pid>|is-napping <pid>|list|stop|ensure-running|watch}"
        exit 1
        ;;
esac
