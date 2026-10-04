# OMARAM Guard

<p align="center">
  <img src="assets/preview.png" width="49%" alt="OMARAM Guard Monitor" />
  <img src="assets/menu.png" width="49%" alt="OMARAM Guard Process Actions" />
</p>

A native Omarchy shell widget that monitors system memory, dispatches proactive desktop alerts, and provides an interactive terminal UI for pausing, inspecting, diagnosing with AI, or killing memory-heavy processes.

## Features
- **Live Memory Indicator & Proactive Alerts:** Changes from normal to amber (75%+) to red (90%+) on your top bar. Automatically fires Omarchy desktop notifications when RAM crosses 80% (Warning) and 90% (Critical).
- **Click-to-Open Notifications:** Clicking any memory alert toast immediately opens the floating OMARAM Guard window.
- **Floating Interactive Manager:** Clicking the bar widget or alert toast launches a perfectly sized (`515x410`), floating, centered terminal UI with 64 character columns.
- **Process Tree Aggregation:** Automatically groups multi-process applications (Chromium, Brave, Electron, VS Code) under their root parent process with combined memory and child counts (e.g. `chromium (23 procs) — 4.3 GB`), preventing helper processes from crowding the monitor.
- **Linux PSI (Pressure Stall Information):** Directly monitors kernel memory pressure stalls (`/proc/pressure/memory`) to differentiate between benign cached disk RAM and true memory starvation/thrashing.
- **Context-Aware Process Actions:** Dynamically adapts available actions based on whether the selected application is actively running or already suspended:
  - `Restart Process`: Safely re-launches the application to flush RAM instantly while strictly preserving sandbox confinement (detects namespaces, Flatpaks, and containers to prevent host code execution, restarting Flatpaks via their sandbox launcher).
  - `Pause (SIGSTOP)`: (Shown when running) Freezes execution to halt runaway memory growth without losing unsaved application state.
  - `Resume (SIGCONT)`: (Shown when paused) Resumes a suspended process once system pressure subsides.
  - `Diagnose with AI (SIGSTOP)`: Freezes the process and launches Omarchy's default AI agent (`omarchy-agent`). Automatically snaps OMARAM Guard into tiled mode if currently floating, positioning the process monitor and the diagnostic agent terminal side-by-side without visual overlap.
  - `Kill (SIGKILL)`: Immediately terminates unresponsive processes and their child helper processes.
- **Zero Config Pollution:** Transient Hyprland floating rules applied ephemerally on launch without modifying your persistent configuration files.

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
- **No Environment Token Leaks:** The agent is explicitly prohibited from reading `/proc/$PID/environ`, which frequently stores decrypted secrets, tokens, and SSH keys.
- **No Raw Memory Dumping:** Banned from reading or dumping `/proc/$PID/mem`.
- **Metadata-Only File Inspection:** Symlinks under `/proc/$PID/fd/` are inspected solely for file paths, locks, and network sockets; reading private user documents (`.txt`, `.pdf`, `.json`) is forbidden.
- **Ephemeral File Hygiene:** Intermediate analysis files must be written strictly to temporary paths via `mktemp -t omaram-XXXXXX` and deleted upon exit via `trap 'rm -f "$tmp"' EXIT`. No dumps remain in `/tmp`.

### 6. Diagnostic Discipline & Upstream Reporting Guardrails
- **Read-Only Non-Destructive Invariant:** *"Diagnosis reads; it does not destroy."* The agent diagnoses memory allocation facts and presents a numbered action menu; it never terminates, unpauses, or restarts applications without explicit user confirmation.
- **Human-in-the-Loop Reporting:** If memory bloat is traced to an Omarchy bug, reporting upstream requires explicit user consent, authentication check via `gh auth status`, search against existing GitHub issues to prevent duplicates, and provenance disclosure (`> Diagnosed by <model> via <agent>`).

### 7. Subshell & Injection Prevention
- **Direct `/proc/meminfo` Parsing:** Memory polling runs directly against `/proc/meminfo` in pure bash without spawning `free` and `awk` every 5 seconds.
- **Bounds Checking:** Exit codes are clamped to $0\text{–}100$, preventing false critical alarms if a process errors.
- **Safe Command Invocation:** Notifications and launchers use discrete argument vectors and safely escaped paths.

### 8. Automated Security Verification
All security and privacy invariants are continuously tested in the repository via [`tests/test_security.py`](tests/test_security.py):
```bash
python3 tests/test_security.py -v
```

## Roadmap & Future Capabilities

OMARAM Guard is actively evolving into a complete, modern memory management tool for the Omarchy desktop:

### Delivered in Development (Milestone: [v1.2.0](https://github.com/layolayo/omarchy-memory-guard/milestone/1) & [v1.3.0](https://github.com/layolayo/omarchy-memory-guard/milestone/2))
- [x] **Process Tree Aggregation & True Reclaim (USS/PSS):** Multi-process browsers and Electron apps collapse into single line items with total combined RAM and child counts. Parses `/proc/$PID/smaps_rollup` to display actual recoverable private memory. ([#1](https://github.com/layolayo/omarchy-memory-guard/issues/1))
- [x] **Linux PSI Integration:** Kernel memory pressure stall tracking (`/proc/pressure/memory`) to differentiate between disk cache and true thrashing.
- [x] **Group Signal Propagation:** Synchronized termination and pausing across parent and child helper processes.
- [x] **Memory Growth Velocity (Leak Indicators):** Real-time trend arrows (`↑` rapid growth $\ge 30$ MB/min, `↓` reclaiming, `→` stable) to instantly separate stable heavy apps from active runaway memory leaks. ([#2](https://github.com/layolayo/omarchy-memory-guard/issues/2))
- [x] **Child Tab Inspection:** A drill-down view in the action menu for aggregated process trees to inspect and terminate individual child renderers without closing the entire parent application. ([#2](https://github.com/layolayo/omarchy-memory-guard/issues/2))
- [x] **Smart App Nap (Focus-Aware Suspension):** Automatically pause heavy background apps (`SIGSTOP`) and wake them (`SIGCONT`) when you focus their window via Hyprland socket events, with strict title-discarding privacy mitigation. ([#3](https://github.com/layolayo/omarchy-memory-guard/issues/3))

### 🔮 Planned for v1.4 (Milestone: [v1.3.0](https://github.com/layolayo/omarchy-memory-guard/milestone/2))
- [ ] **OOM Post-Mortem Notifications:** Desktop notifications explaining why a background application disappeared when killed by the kernel OOM killer or `systemd-oomd`. ([#4](https://github.com/layolayo/omarchy-memory-guard/issues/4))
- [ ] **AI Differential Profiling:** 30-second snapshot comparison in AI diagnostics to pinpoint leaking memory regions, unclosed file descriptors, or infinite loops. ([#5](https://github.com/layolayo/omarchy-memory-guard/issues/5))

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
