# OMARAM Guard

<p align="center">
  <img src="assets/preview.png" width="49%" alt="OMARAM Guard Monitor" />
  <img src="assets/menu.png" width="49%" alt="OMARAM Guard Process Actions" />
</p>

A native Omarchy shell widget that monitors system memory, dispatches proactive desktop alerts, and provides an interactive terminal UI for pausing, inspecting, diagnosing with AI, or killing memory-heavy processes.

## Features
- **Live Memory Indicator & Proactive Alerts:** Changes from normal to amber (75%+) to red (90%+) on your top bar. Automatically fires Omarchy desktop notifications when RAM crosses 80% (Warning) and 90% (Critical).
- **Click-to-Open Notifications:** Clicking any memory alert toast immediately opens the floating OMARAM Guard window.
- **Floating Interactive Manager:** Clicking the bar widget or alert toast launches a perfectly sized (`465x425`), floating, centered terminal UI powered by `gum`.
- **Safe Process Management:** Lists top memory-hungry applications dynamically. Allows you to:
  - `Pause (SIGSTOP)`: Freeze runaway memory growth without losing unsaved application state.
  - `Diagnose with AI (SIGSTOP)`: Freeze the process and launch Omarchy's default AI agent (`omarchy-agent`) in a floating window to inspect memory allocations, open files, and journal logs to recommend `SIGCONT` vs `SIGKILL`.
  - `Resume (SIGCONT)`: Unfreeze a paused process once system pressure subsides.
  - `Kill (SIGKILL)`: Immediately terminate unresponsive or runaway processes.
- **Zero Config Pollution:** Transient Hyprland floating rules applied ephemerally on launch without modifying your persistent configuration files.
- **Hardened Security:** Strictly sandboxed to unprivileged user execution (`ps -U "$USER"`).

## Installation

Add this plugin to Omarchy using the CLI:
```bash
omarchy plugin add https://github.com/layolayo/omarchy-memory-guard
```

## Setup

Move the widget into your bar:
```bash
omarchy bar put io.github.layolayo.memory-guard --section center
```

## Dependencies
- `gum`: Required for the interactive terminal UI. (Included with Omarchy desktop installations).
- `omarchy-agent`: (Optional) Required for interactive AI memory diagnosis.

## Removal
To completely remove the plugin from your system:
```bash
omarchy plugin remove io.github.layolayo.memory-guard --yes
```
