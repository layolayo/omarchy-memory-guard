#!/bin/bash
set -euo pipefail

# Read MemTotal and MemAvailable directly from /proc/meminfo.
# This avoids spawning subshells (free, awk) every 5 seconds.
# MemAvailable is the Linux kernel's official metric for non-swap memory availability.

if [[ ! -r /proc/meminfo ]]; then
    exit 255
fi

total=0
avail=0

while read -r key val _; do
    case "$key" in
        MemTotal:) total="$val" ;;
        MemAvailable:) avail="$val" ;;
    esac
    if (( total > 0 && avail > 0 )); then
        break
    fi
done < /proc/meminfo

if (( total <= 0 )); then
    exit 255
fi

# Calculate percentage used based on available memory
used=$(( total - avail ))
pct=$(( (used * 100) / total ))

# Clamp between 0 and 100
if (( pct < 0 )); then pct=0; fi
if (( pct > 100 )); then pct=100; fi

exit "$pct"
