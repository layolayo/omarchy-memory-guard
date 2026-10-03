# Diagnosing a High-Memory Paused Process

When a process is paused (`SIGSTOP`) from **OMARAM Guard**, it is frozen on the threshold of an Out-Of-Memory (OOM) crash or system lockup. The goal of this investigation is to provide an honest, evidence-based account of why the process is consuming excessive memory, whether user data is at risk, and whether it is safe to resume or terminate.

---

## 1. Principles

1. **Work from evidence:** The goal is an honest account of the process state, not guesswork. Separate clearly what `/proc` and logs **prove** from what you are **inferring**.
2. **Diagnosis reads; it does not destroy:** The investigation inspects the process; it does not unpause, kill, or modify files without explicit user consent.
3. **The process is alive:** Unlike a core dump from a crashed program, the process address space is completely intact in RAM. You have access to active file descriptors, memory maps, thread states, and environmental context.
4. **Privacy & Data Protection Invariants:**
   - **Never read `/proc/<pid>/environ`:** Environment variables routinely store API tokens, SSH/database secrets, and authorization keys.
   - **Never dump or read `/proc/<pid>/mem`:** Raw memory pages can contain decrypted credentials and private in-memory documents.
   - **Metadata only for open files:** Inspect `/proc/<pid>/fd/` symlinks solely to identify file paths, file extensions, and lock statuses. Never read the contents of personal user documents (`.txt`, `.pdf`, `.json`, etc.).
   - **Redact secrets in reports:** If command lines or logs contain accidental tokens or sensitive parameters, mask them immediately with `[REDACTED]`.
5. **Ephemeral File Hygiene:**
   - If generating intermediate diagnostic summaries or memory analysis dumps, write only to a fresh `mktemp -t omaram-XXXXXX` path rather than a predictable shared location.
   - Clean up with a trap (`trap 'rm -f "$tmp"' EXIT`) and delete temporary artifacts before exiting—never leave memory snapshots or diagnostic dumps lying in `/tmp`.
6. **Sandbox Boundary Preservation:**
   - Confined applications (Flatpak, Snap, bubblewrap, or containerized environments) must preserve their containment boundaries.
   - Never execute mutable command-line arguments on the unconfined host for sandboxed processes. Restart confined processes strictly through their original container launcher (e.g. `flatpak run <app-id>`) or defer to the desktop application launcher.

---

## 2. Investigation Protocol

### Step 1: Establish Facts
Inspect the process boundaries under `/proc/<pid>/`:
- **Command Line & Arguments:** `/proc/<pid>/cmdline` (delimited by NUL bytes) shows exact arguments, flags, input files, and scripts (pre-sanitized by OMARAM Guard).
- **Process Hierarchy:** `/proc/<pid>/status` `PPid` reveals the parent process (e.g. browser parent vs renderer child, terminal shell vs background job).
- **Working Directory:** `readlink -f /proc/<pid>/cwd` shows what directory or project the process is operating on.

### Step 2: Analyze Memory Composition
Read `/proc/<pid>/smaps_rollup` and `/proc/<pid>/status`:
- **Private Dirty / Anonymous:** Memory allocated on the heap or stack that cannot be dropped. High private dirty memory confirms real application allocation or a memory leak.
- **Shared / File-backed (mmap):** Shared libraries or files mapped into memory (e.g. video assets, font caches, databases). The Linux kernel can reclaim or page out clean file-backed memory if needed.
- **Swap Usage (`VmSwap`):** If swap is heavily utilized, the process has already pushed other applications out of physical RAM and is risking disk I/O thrashing.

### Step 3: Inspect In-Flight Work & File Handles
Inspect `/proc/<pid>/fd/`:
- **Open Documents / Files:** Look for file descriptors pointing to documents, databases, git repositories, or video/audio streams.
- **Sockets & Pipes:** Sockets indicate active network downloads, RPC calls, or IPC with other desktop services.
- **Risk Assessment:** Closing or killing a process holding write locks or uncommitted database transactions risks data corruption.

### Step 4: Check Timeline & System Logs
Correlate against systemd journal:
```bash
journalctl _PID=<pid> --since "15 minutes ago" --no-pager
```
Look for memory warnings, garbage collection failures, unhandled exceptions, or endless repetitive logging indicating an infinite loop.

---

## 3. What the Report Must Provide

Produce a concise, well-structured diagnostic report:

1. **Identity & Active Work:**
   - What application/script this is, what arguments it was invoked with, and what it was actively doing when paused.
2. **Memory Breakdown (Proven Facts):**
   - RSS vs PSS vs Swap.
   - Whether the memory is private heap bloat or shared/cached files.
3. **Root Cause Analysis:**
   - Is this a genuine memory leak (unbounded heap / event listeners / buffers)?
   - A runaway execution loop?
   - Or legitimate, expected high-memory workload (e.g., local LLM weights, compiler AST cache, large video render)?
4. **Data Safety & Collateral Damage:**
   - Will killing the process cause unsaved data loss?
   - Is it an isolated child (e.g., a single browser tab) where termination will only crash that tab without affecting the parent browser?
5. **Clear Actionable Recommendations & Execution:**
   The report should conclude with an explicit, numbered Action Menu, and offer to execute the user's choice:
   - **[1] 💀 Terminate (`kill -9 <pid>`)** — If it is an unrecoverable leak or frozen loop, immediately reclaim all RAM.
   - **[2] 🔄 Clean Restart** — Terminate the frozen process and re-launch a fresh instance using its original command line and working directory, while strictly preserving sandbox boundaries (re-launching Flatpaks via `flatpak run` and skipping host restarts for confined/containerized processes).
   - **[3] ▶️ Resume (`kill -CONT <pid>`)** — If the memory usage was legitimate/temporary, or if the user needs to resume briefly to save work before orderly exit.
   - **[4] 🎯 Targeted Reclaim** — If closing a specific child tab, document, or thread can free memory without bringing down the entire parent application.
6. **Provenance Signing:**
   End the report with a line naming the model and agent harness that produced it:
   > Diagnosed by \<model name\> via \<agent harness\>.

---

## 4. Upstream Reporting Guardrails (If it is an Omarchy bug)

Read this only after concluding that a memory leak or runaway loop sits genuinely within Omarchy's sphere of control (e.g., `omarchy-shell`, bar plugins, quickshell, themes, or core scripts):

1. **Three conditions, all required:**
   - **Verified bug in Omarchy's sphere:** A memory bloat in a standard third-party application (Chromium, Firefox, Electron app, or Python tool) is an upstream application issue, not Omarchy's bug.
   - **Explicit user agreement:** Present the exact title and body you propose to file, and wait for confirmation. Never file unprompted.
   - **Authenticated GitHub CLI:** `gh auth status` must succeed. If unauthenticated, hand the formatted text to the user to submit manually.
2. **Search before filing:**
   ```bash
   gh search issues --repo omacom/omarchy "<component> memory leak"
   ```
   Check open and closed issues for regressions before creating duplicates.
3. **Sign the report:**
   Include system diagnostics from `omarchy version` and sign machine-authored reports.
