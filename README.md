# OMARAM Guard

<p align="center">
  <img src="assets/preview.png" width="49%" alt="OMARAM Guard Monitor" />
  <img src="assets/menu.png" width="49%" alt="OMARAM Guard Process Actions" />
</p>

A native Omarchy shell widget that monitors system memory, dispatches proactive desktop alerts, and provides an interactive terminal UI for pausing, inspecting, diagnosing with AI, or killing memory-heavy processes.

## Features
- **Live Memory Indicator & Proactive Alerts:** Changes from normal to amber (75%+) to red (90%+) on your top bar. Automatically fires Omarchy desktop notifications when RAM crosses 80% (Warning) and 90% (Critical).
- **Click-to-Open Notifications:** Clicking any memory alert toast immediately opens the floating OMARAM Guard window.
- **Floating Interactive Manager:** Clicking the bar widget or alert toast launches a perfectly sized (`465x480`), floating, centered terminal UI powered by `gum`.
- **Context-Aware Process Actions:** Dynamically adapts available actions based on whether the selected application is actively running or already suspended:
  - `Restart Process`: Captures the process's working directory and command-line arguments, kills the bloated instance, and re-launches it fresh in the background to flush RAM instantly.
  - `Pause (SIGSTOP)`: (Shown when running) Freezes execution to halt runaway memory growth without losing unsaved application state.
  - `Resume (SIGCONT)`: (Shown when paused) Resumes a suspended process once system pressure subsides.
  - `Diagnose with AI (SIGSTOP)`: Freezes the process and launches Omarchy's default AI agent (`omarchy-agent`). Automatically snaps OMARAM Guard into tiled mode if currently floating, positioning the process monitor and the diagnostic agent terminal side-by-side without visual overlap.
  - `Kill (SIGKILL)`: Immediately terminates unresponsive processes.
- **Zero Config Pollution:** Transient Hyprland floating rules applied ephemerally on launch without modifying your persistent configuration files.

## Security & Privacy Architecture

OMARAM Guard manages active processes and interfaces with system internals and AI diagnostics. It enforces a strict **defense-in-depth security model** aligned with Omarchy's system crash handler and privacy standards:

### 1. Process & UID Boundary Isolation
- **Strict Ownership Verification:** Before any signal (`SIGKILL`, `SIGSTOP`, `SIGCONT`) is dispatched, OMARAM Guard verifies `/proc/$PID` ownership matches `$UID`. Root processes, system daemons, and other users' applications are strictly rejected.
- **Anti-Suicide & Self-Protection Invariants:** The guard script itself (`$$`), its parent shell (`$PPID`), and terminal wrappers are barred from selection, preventing accidental interface termination or lockups.
- **Strict PID Validation:** All input PIDs are strictly validated as positive integers $> 1$. Empty, negative, or injection strings (such as `1; rm -rf /`) are rejected before executing shell commands.

### 2. Process Name & Path Traversal Sanitization
- **Component Stripping:** Processes can alter their command name (`comm` via `prctl`) to contain arbitrary characters including path separators (`/`) or dot traversal (`..`). OMARAM Guard strips all leading directory components (`comm=${comm##*/}`) and falls back to a safe identifier if empty or invalid.
- **Control Character Filtering:** Binary, ANSI escape sequences, and terminal control characters are stripped from process names and arguments before rendering or passing to AI agents, eliminating terminal injection attacks.

### 3. Automated Inline Credential Redaction
When triggering **Diagnose with AI**, command-line arguments are sanitized through an automated multi-stage redaction pipeline before prompt construction:
- **API Keys & Tokens:** Masks GitHub tokens (`ghp_`, `github_pat_`), GitLab tokens (`glpat-`), Slack tokens (`xoxb-`), OpenAI/Anthropic keys (`sk-`), and Bearer authentication headers.
- **Credentials & Passwords:** Masks inline flags (`--password`, `--token`, `--api-key`, `--client-secret`, `-p`, `-u`) and basic auth database/HTTP URLs (`https://user:[REDACTED]@host`).

### 4. Privacy Invariants for AI Diagnostics
OMARAM Guard provides the diagnostic agent with system facts while maintaining strict data protection invariants:
- **No Environment Token Leaks:** The agent is explicitly prohibited from reading `/proc/$PID/environ`, which frequently stores decrypted secrets, tokens, and SSH keys.
- **No Raw Memory Dumping:** Banned from reading or dumping `/proc/$PID/mem`.
- **Metadata-Only File Inspection:** Symlinks under `/proc/$PID/fd/` are inspected solely for file paths, locks, and network sockets; reading private user documents (`.txt`, `.pdf`, `.json`) is forbidden.
- **Ephemeral File Hygiene:** Intermediate analysis files must be written strictly to temporary paths via `mktemp -t omaram-XXXXXX` and deleted upon exit via `trap 'rm -f "$tmp"' EXIT`. No dumps remain in `/tmp`.

### 5. Diagnostic Discipline & Upstream Reporting Guardrails
- **Read-Only Non-Destructive Invariant:** *"Diagnosis reads; it does not destroy."* The agent diagnoses memory allocation facts and presents a numbered action menu; it never terminates, unpauses, or restarts applications without explicit user confirmation.
- **Human-in-the-Loop Reporting:** If memory bloat is traced to an Omarchy bug, reporting upstream requires explicit user consent, authentication check via `gh auth status`, search against existing GitHub issues to prevent duplicates, and provenance disclosure (`> Diagnosed by <model> via <agent>`).

### 6. Subshell & Injection Prevention
- **Direct `/proc/meminfo` Parsing:** Memory polling runs directly against `/proc/meminfo` in pure bash without spawning `free` and `awk` every 5 seconds.
- **Bounds Checking:** Exit codes are clamped to $0\text{–}100$, preventing false critical alarms if a process errors.
- **Safe Command Invocation:** Notifications and launchers use discrete argument vectors and safely escaped paths.

### 7. Automated Security Verification
All security and privacy invariants are continuously tested in the repository via [`tests/test_security.py`](tests/test_security.py):
```bash
python3 tests/test_security.py -v
```

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
