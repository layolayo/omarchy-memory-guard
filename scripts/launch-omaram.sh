#!/bin/bash
# OMARAM Guard Floating Window Launcher

# Register transient Hyprland window rule for perfect floating dimensions without touching persistent config
hyprctl eval 'o.window({ title = "^(OMARAM-GUARD)$" }, { float = true, center = true, size = { 465, 425 } })' 2>/dev/null || true

# Resolve plugin script directory dynamically
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Launch interactive TUI in floating terminal via setsid and uwsm
exec setsid uwsm-app -- xdg-terminal-exec --app-id=org.omarchy.terminal.omaram --title=OMARAM-GUARD -e bash -c "source omarchy-restart-gum 2>/dev/null || true; exec \"$SCRIPT_DIR/omaram-guard.sh\""
