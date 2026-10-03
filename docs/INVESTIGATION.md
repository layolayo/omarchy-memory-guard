# Diagnosing a High-Memory Paused Process

When a process is paused (`SIGSTOP`) from **OMARAM Guard**, it is frozen on the threshold of an Out-Of-Memory (OOM) crash or system lockup. The goal of this investigation is to provide an honest, evidence-based account of why the process is consuming excessive memory, whether user data is at risk, and whether it is safe to resume or terminate.

---

## 1. Principles

1. **Work from evidence:** The goal is an honest account of the process state, not guesswork. Separate clearly what `/proc` and logs **prove** from what you are **inferring**.
2. **Diagnosis reads; it does not destroy:** The investigation inspects the process; it does not unpause, kill, or modify files without explicit user consent.
3. **The process is alive:** Unlike a core dump from a crashed program, the process address space is completely intact in RAM. You have access to active file descriptors, memory maps, thread states, and environmental context.

---

## 2. Investigation Protocol

### Step 1: Establish Facts
Inspect the process boundaries under `/proc/<pid>/`:
- **Command Line & Arguments:** `/proc/<pid>/cmdline` (delimited by NUL bytes) shows exact arguments, flags, input files, and scripts.
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
5. **Clear Actionable Recommendations:**
   - **Option A: Resume (`kill -CONT <pid>`)** — If the memory usage was legitimate and temporary, or if the user should resume briefly to save work before orderly shutdown.
   - **Option B: Targeted Reclaim** — If closing a specific document, tab, or child thread can release memory without killing the process.
   - **Option C: Terminate (`kill -9 <pid>`)** — If it is an unrecoverable leak or frozen loop, with advice on how to prevent recurrence upon restart.
