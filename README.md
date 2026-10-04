# OMARAM Guard

<p align="center">
  <img src="assets/preview.png" width="32.5%" alt="OMARAM Guard Monitor" />
  <img src="assets/menu.png" width="32.5%" alt="OMARAM Guard Process Actions" />
  <img src="assets/ai.png" width="32.5%" alt="OMARAM Guard AI Diagnostics" />
</p>

A native Omarchy shell widget that monitors system memory, dispatches proactive desktop alerts, and provides an interactive terminal UI for pausing, inspecting, profiling with differential snapshots, diagnosing with AI, or killing memory-heavy processes.

## Features
- **Live Memory Indicator & Proactive Alerts:** Changes from normal to amber (75%+) to red (90%+) on your top bar. Automatically fires Omarchy desktop notifications when RAM crosses 80% (Warning) and 90% (Critical).
- **Click-to-Open Notifications:** Clicking any memory alert toast immediately opens the floating OMARAM Guard window.
- **Floating Interactive Manager:** Clicking the bar widget or alert toast launches a perfectly sized (`515x410`), floating, centered terminal UI with 64 character columns.
- **Process Tree Aggregation & Child Tab Inspection:** Automatically groups multi-process applications (Chromium, Brave, Electron, VS Code) under their root parent process with combined memory and child counts (e.g. `chromium (24 procs) — 4.3 GB`), preventing helper processes from crowding the monitor. Drill down into individual child renderers and workers to terminate rogue tabs without closing the main application.
- **Friendly Desktop Application Name Resolution:** Automatically correlates generic VM and interpreter processes (`java`, `python3`, `node`, `electron`) with active Hyprland Wayland client window classes, displaying intuitive desktop application names (e.g. `DBeaver`, `IntelliJ IDEA`, `Inkscape`).
- **Smart App Nap (Focus & Workspace-Aware Suspension):**
  - Automatically suspends background applications (`SIGSTOP`) when their window loses focus or moves to an inactive workspace, and wakes them (`SIGCONT`) upon focus.
  - **Multi-Monitor Awareness:** Apps remain awake (`☀️`) if visible on any active monitor's workspace, entering sleep (`💤`) only when hidden.
  - **Smart Tab Nap:** For multi-process applications (Chromium, Firefox, Electron), leaves the root process running to handle Wayland compositor pings, audio playback, and active downloads while suspending heavy worker/renderer processes holding 85–95% of memory.
  - **Zero-Flicker Live Status:** Dynamically swaps status emojis (`☀️` <-> `💤`) in place via Hyprland IPC socket events without rebuilding the viewport or shifting cursor navigation.
- **Memory Growth Velocity (Leak Indicators):** Real-time allocation trend arrows (`↑` rapid growth $\ge 30$ MB/min, `↓` reclaiming, `→` stable) to immediately separate stable heavy apps from active runaway memory leaks.
- **In-Place Action Feedback:** User notifications and feedback cards replace the centered selection box directly in-place with zero terminal scrolling or header disruption.
- **Linux PSI (Pressure Stall Information):** Directly monitors kernel memory pressure stalls (`/proc/pressure/memory`) to differentiate between benign cached disk RAM and true memory starvation/thrashing.
- **Context-Aware Process Actions & Dedicated AI Submenu:** Dynamically adapts available actions based on whether the selected application is actively running, sleeping, or suspended:
  - `Toggle Smart App Nap (Auto-Sleep)`: Configures automatic background suspension for the selected application.
  - `Inspect Child Tabs / Workers`: (Multi-process apps) Drills down into individual child renderers and helper processes.
  - `Restart Process`: Safely re-launches the application to flush RAM instantly while strictly preserving sandbox confinement (detects namespaces, Flatpaks, and containers to prevent host code execution, restarting Flatpaks via their official sandbox launcher).
  - `Pause (SIGSTOP)` / `Resume (SIGCONT)`: Freezes execution to halt runaway memory growth or resumes suspended processes once system pressure subsides.
  - `🤖 Diagnose with AI`: Opens a dedicated **AI Diagnostic Mode** submenu:
    - `⚡ Instant Diagnostics`: Freezes the process with `SIGSTOP`, automatically snaps OMARAM Guard into tiled mode side-by-side, and launches Omarchy's default AI agent (`omarchy-agent`).
    - `📸 30s Differential Profiler`: Samples memory growth rate ($\Delta\text{USS}$, $\Delta\text{PSS}$ in MB/min), file descriptor/socket leak churn, and thread drift over 30 seconds with a live progress card before attaching the AI agent.
    - `⏱️ 10s Quick Differential Profiler`: Fast 10-second delta check for aggressive runaway allocations.
  - `Kill (SIGKILL)`: Immediately terminates unresponsive processes and their child helper processes.
- **Visual AI Attention Indicator (`🤖`):** Processes frozen under active AI diagnosis display a distinct `🤖` indicator in the `STATE` column across the main table, selection headers, and child tab lists.
- **Zero Config Pollution:** Transient Hyprland floating rules applied ephemerally on launch without modifying persistent configuration files.

### Understanding Memory Metrics: RSS, USS, and PSS

Standard Linux utilities (`ps`, `top`) only report **RSS**, which can be misleading when diagnosing memory pressure or deciding which application to terminate. When any application is selected, OMARAM Guard queries `/proc/$PID/smaps_rollup` in sub-millisecond time to provide an honest breakdown:

| Metric | Full Name | What It Measures | Practical Meaning |
| :--- | :--- | :--- | :--- |
| **RSS** | *Resident Set Size* | Total physical RAM mapped into the process's page table. | Includes shared libraries (`libc.so`, graphics drivers, fonts) shared with other programs. Terminating the process will **not** free this shared memory. |
| **USS** | *Unique Set Size* *(True Reclaim)* | Private physical RAM (`Private_Clean + Private_Dirty`) exclusive to this process. | **The actual RAM you will get back.** This memory is guaranteed to be returned to the OS immediately if the process is terminated. |
| **PSS** | *Proportional Set Size* | Private RAM plus a proportional fraction of shared libraries. | If a 100 MB library is shared by 5 apps, each app accounts for 20 MB in its PSS. Represents the app's fair-share memory footprint. |
| **PSI** | *Pressure Stall Information* | Percentage of CPU time threads spend stalled on memory/swap I/O. | Distinguishes full RAM used for fast disk cache (smooth system) from true memory thrashing (stuttering/freezing desktop). |

## Security & Privacy Architecture

OMARAM Guard manages active processes and interfaces with system internals and AI diagnostics. It enforces a strict **defense-in-depth security model** aligned with Omarchy's system crash handler and privacy standards:

### 1. Process & UID Boundary Isolation
- **Strict Ownership Verification:** Before any signal (`SIGKILL`, `SIGSTOP`, `SIGCONT`) is dispatched, OMARAM Guard verifies `/proc/$PID` ownership matches `$UID`. Root processes, system daemons, and other users' applications are strictly rejected.
- **Anti-Suicide & Self-Protection Invariants:** The guard script itself (`$$`), its parent shell (`$PPID`), and terminal wrappers are barred from selection, preventing accidental interface termination or lockups.
- **Strict PID Validation:** All input PIDs are strictly validated as positive integers $> 1$. Empty, negative, or injection strings (such as `1; rm -rf /`) are rejected before executing shell commands.

### 2. Sandbox Boundary Preservation & Host Execution Defense
- **Container & Namespace Boundary Detection:** Before initiating any process restart, `is_confined_or_sandboxed` evaluates mount namespaces (`/proc/$$/ns/mnt`), user namespaces (`/proc/$$/ns/user`), PID namespaces, root filesystem divergence (`/proc/$PID/root`), `.flatpak-info` presence, and container/sandbox cgroups (`app-flatpak`, `snap.`, `docker`, `containerd`, `bwrap`, `sandbox`).
- **Sandbox Escape Prevention:** A sandboxed or containerized application running under the same user UID cannot escape its confinement by rewriting its mutable `/proc/$PID/cmdline` to execute arbitrary host commands upon restart.
- **Dedicated Sandbox Launcher Restart:** Flatpak processes are safely restarted via their official sandbox launcher (`flatpak run $APP_ID`). All other confined processes (Docker, Podman, bubblewrap, custom namespaces) explicitly refuse host re-execution with a user alert advising them to launch from their application menu.
- **Kernel-Verified Executable Enforcement:** For unconfined host processes, `CMD_ARGS[0]` is strictly locked to the kernel-verified `/proc/$PID/exe` binary path, preventing mutable `argv[0]` manipulation from invoking arbitrary commands.
- **Interpreter Code Injection Defense:** Restarts of shells and interpreters (`bash`, `sh`, `zsh`, `python`, `node`, `ruby`, `perl`, `php`) strictly block inline execution flags (`-c`, `-e`, `--eval`, `--command`) from reconstructed command lines.

### 3. Process Name & Path Traversal Sanitization
- **Component Stripping:** Processes can alter their command name (`comm` via `prctl`) to contain arbitrary characters including path separators (`/`) or dot traversal (`..`). OMARAM Guard strips all leading directory components (`comm=${comm##*/}`) and falls back to a safe identifier if empty or invalid.
- **Control Character Filtering:** Binary, ANSI escape sequences, and terminal control characters are stripped from process names and arguments before rendering or passing to AI agents, eliminating terminal injection attacks.

### 4. Automated Inline Credential Redaction
When triggering **Diagnose with AI**, command-line arguments are sanitized through an automated multi-stage redaction pipeline before prompt construction:
- **API Keys & Tokens:** Masks GitHub tokens (`ghp_`, `github_pat_`), GitLab tokens (`glpat-`), Slack tokens (`xoxb-`), OpenAI/Anthropic keys (`sk-`), and Bearer authentication headers.
- **Credentials & Passwords:** Masks inline flags (`--password`, `--token`, `--api-key`, `--client-secret`, `-p`, `-u`) and basic auth database/HTTP URLs (`https://user:[REDACTED]@host`).

### 5. Privacy Invariants for AI Diagnostics
OMARAM Guard provides the diagnostic agent with system facts while maintaining strict data protection invariants:
- **No Protected Path Leaks in Public Arguments:** Binary (`/proc/$PID/exe`) and working directory (`/proc/$PID/cwd`) paths are never interpolated into prompt arguments passed to `omarchy-agent`. This prevents private executable and workspace directories from being exposed to other local Unix users via `/proc/*/cmdline` or process tables on standard procfs configurations. The AI agent inspects them directly in-session as the authenticated process owner.
- **No Environment Token Leaks:** The agent is explicitly prohibited from reading `/proc/$PID/environ`, which frequently stores decrypted secrets, tokens, and SSH keys.
- **No Raw Memory Dumping:** Banned from reading or dumping `/proc/$PID/mem`.
- **Metadata-Only File Inspection:** Symlinks under `/proc/$PID/fd/` are inspected solely for file paths, locks, and network sockets; reading private user documents (`.txt`, `.pdf`, `.json`) is forbidden.
- **Ephemeral File Hygiene:** Intermediate analysis files must be written strictly to temporary paths via `mktemp -t omaram-XXXXXX` with restrictive `0600` permissions and deleted upon exit via `trap 'rm -f "$tmp"' EXIT`. No dumps remain in `/tmp`.

### 6. Differential Memory Profiling Security & Non-Invasive Sampling
- **Non-Invasive Sampling:** The differential profiler samples `/proc/$PID/status`, `/proc/$PID/smaps_rollup`, and `/proc/$PID/fd/` symlink destinations without attaching ptrace, injecting code, or reading socket/file payload data.
- **Document Path & Argument Privacy Guardrail:** Full filesystem paths of opened files are strictly excluded from differential profile reports and public command-line arguments to prevent exposing sensitive user document paths via `/proc/*/cmdline` or process listings to other local users. Only aggregated descriptor counts and non-filesystem kernel handles (`socket:[...]`, `pipe:[...]`, `anon_inode:[...]`) are included in diagnostic summaries.
- **Ephemeral Snapshot Transport:** Temporary snapshot files are generated with mode `0600` (`chmod 600 "$snap_tmp"`) and cleaned up immediately upon agent launch or profiling abort.

### 7. Shell Script AST Scoping Integrity
- **Function Scoping Verification:** All Bash scripts are statically validated via `test_no_local_outside_functions` to ensure variable scoping builtins (`local`) are strictly confined within function bodies, preventing runtime shell syntax crashes.

### 8. Diagnostic Discipline & Upstream Reporting Guardrails
- **Read-Only Non-Destructive Invariant:** *"Diagnosis reads; it does not destroy."* The agent diagnoses memory allocation facts and presents a numbered action menu; it never terminates, unpauses, or restarts applications without explicit user confirmation.
- **Human-in-the-Loop Reporting:** If memory bloat is traced to an Omarchy bug, reporting upstream requires explicit user consent, authentication check via `gh auth status`, search against existing GitHub issues to prevent duplicates, and provenance disclosure (`> Diagnosed by <model> via <agent>`).

### 9. Subshell & Injection Prevention
- **Direct `/proc/meminfo` Parsing:** Memory polling runs directly against `/proc/meminfo` in pure bash without spawning `free` and `awk` every 5 seconds.
- **Bounds Checking:** Exit codes are clamped to $0\text{–}100$, preventing false critical alarms if a process errors.
- **Safe Command Invocation:** Notifications and launchers use discrete argument vectors and safely escaped paths.

### 10. Automated Security & Functional Verification
All security, privacy, and functional invariants are continuously verified via the comprehensive automated test suite:
```bash
python3 -m unittest discover -s tests -v
```

## Roadmap & Milestone Status

OMARAM Guard is actively developed for the Omarchy desktop:

### Delivered Capabilities (Milestones: [v1.2.0](https://github.com/layolayo/omarchy-memory-guard/milestone/1) & [v1.3.0](https://github.com/layolayo/omarchy-memory-guard/milestone/2))
- [x] **Process Tree Aggregation & True Reclaim (USS/PSS):** Multi-process browsers and Electron apps collapse into single line items with total combined RAM and child counts. Parses `/proc/$PID/smaps_rollup` to display actual recoverable private memory. ([#1](https://github.com/layolayo/omarchy-memory-guard/issues/1))
- [x] **Linux PSI Integration:** Kernel memory pressure stall tracking (`/proc/pressure/memory`) to differentiate between disk cache and true thrashing.
- [x] **Group Signal Propagation:** Synchronized termination and pausing across parent and child helper processes.
- [x] **Memory Growth Velocity (Leak Indicators):** Real-time trend arrows (`↑` rapid growth $\ge 30$ MB/min, `↓` reclaiming, `→` stable) to instantly separate stable heavy apps from active runaway memory leaks. ([#2](https://github.com/layolayo/omarchy-memory-guard/issues/2))
- [x] **Child Tab Inspection:** Drill-down view in the action menu for aggregated process trees to inspect and terminate individual child renderers without closing the entire parent application. ([#2](https://github.com/layolayo/omarchy-memory-guard/issues/2))
- [x] **Smart App Nap (Focus-Aware Suspension):** Automatically pause heavy background apps (`SIGSTOP`) and wake them (`SIGCONT`) when you focus their window via Hyprland socket events, with multi-monitor awareness, smart tab nap, and zero-flicker live status updates. ([#3](https://github.com/layolayo/omarchy-memory-guard/issues/3))
- [x] **Friendly Desktop Application Name Resolution:** Resolves generic VM/interpreter names (`java`, `python3`, `node`, `electron`) to real Wayland window classes (e.g. `DBeaver`).
- [x] **AI Differential Profiling & Submenu:** 30s and 10s differential memory snapshot comparison in AI diagnostics measuring heap growth velocity ($\text{MB/min}$), socket/fd churn, and thread drift before attaching `omarchy-agent`. ([#5](https://github.com/layolayo/omarchy-memory-guard/issues/5))
- [x] **Visual AI Attention Indicator (`🤖`):** Distinguishes processes undergoing AI investigation across the UI and process table.

### 🔮 Planned for v1.4
- [ ] **OOM Post-Mortem Notifications:** Desktop notifications explaining why a background application disappeared when killed by the kernel OOM killer or `systemd-oomd`. ([#4](https://github.com/layolayo/omarchy-memory-guard/issues/4))

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
