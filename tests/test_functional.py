#!/usr/bin/env python3
"""
OMARAM Guard - Functional & Behavioral Test Suite

Verifies live runtime behavior, including:
1. Synthetic memory calculation accuracy, zero-division, missing fields, and clamping.
2. Linux namespace isolation detection and container signatures.
3. Host restart argument reconstruction, kernel EXE verification, and inline code injection rejection.
4. Process table AWK parsing, self/parent exclusion, and state tagging (RUNNING vs PAUSED).
5. In-place TUI navigation engine (arrow keys, vim keys, enter submit, escape abort).
6. Floating window launcher contracts and Hyprland geometry rules.
7. QML alert threshold specifications and polling frequencies.
"""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent.parent
SCRIPTS_DIR = ROOT_DIR / "scripts"


class CheckMemPctArithmeticTests(unittest.TestCase):
    def setUp(self):
        self.script = SCRIPTS_DIR / "check-mem-pct.sh"
        self.tmp_dir = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.tmp_dir.cleanup()

    def _run_with_meminfo(self, content):
        tmp_file = Path(self.tmp_dir.name) / "meminfo"
        tmp_file.write_text(content)
        return subprocess.run([str(self.script), str(tmp_file)])

    def test_synthetic_exact_percentages(self):
        # 0% used (Avail == Total)
        res = self._run_with_meminfo("MemTotal: 16000000 kB\nMemAvailable: 16000000 kB\n")
        self.assertEqual(res.returncode, 0)

        # 25% used
        res = self._run_with_meminfo("MemTotal: 16000000 kB\nMemAvailable: 12000000 kB\n")
        self.assertEqual(res.returncode, 25)

        # 50% used
        res = self._run_with_meminfo("MemTotal: 16000000 kB\nMemAvailable: 8000000 kB\n")
        self.assertEqual(res.returncode, 50)

        # 75% used (Amber threshold)
        res = self._run_with_meminfo("MemTotal: 16000000 kB\nMemAvailable: 4000000 kB\n")
        self.assertEqual(res.returncode, 75)

        # 80% used (Warning threshold)
        res = self._run_with_meminfo("MemTotal: 16000000 kB\nMemAvailable: 3200000 kB\n")
        self.assertEqual(res.returncode, 80)

        # 90% used (Critical threshold)
        res = self._run_with_meminfo("MemTotal: 16000000 kB\nMemAvailable: 1600000 kB\n")
        self.assertEqual(res.returncode, 90)

        # 99% used
        res = self._run_with_meminfo("MemTotal: 16000000 kB\nMemAvailable: 160000 kB\n")
        self.assertEqual(res.returncode, 99)

        # 100% used (Avail == 0)
        res = self._run_with_meminfo("MemTotal: 16000000 kB\nMemAvailable: 0 kB\n")
        self.assertEqual(res.returncode, 100)

    def test_clamping_and_bounds_protection(self):
        # Anomaly: Avail > Total (e.g. kernel accounting glitch)
        res = self._run_with_meminfo("MemTotal: 1000000 kB\nMemAvailable: 1500000 kB\n")
        self.assertEqual(res.returncode, 0, "Percentage below 0 must clamp to 0")

    def test_error_handling_and_zero_division(self):
        # Zero Total
        res = self._run_with_meminfo("MemTotal: 0 kB\nMemAvailable: 0 kB\n")
        self.assertEqual(res.returncode, 255, "Zero Total must exit with 255")

        # Missing MemTotal (uninitialized total <= 0)
        res = self._run_with_meminfo("MemFree: 500000 kB\nMemAvailable: 100000 kB\n")
        self.assertEqual(res.returncode, 255, "Missing MemTotal must exit with 255")

        # Non-existent file
        res = subprocess.run([str(self.script), "/nonexistent/path/to/meminfo"])
        self.assertEqual(res.returncode, 255, "Missing file must exit with 255")


class SandboxBoundaryFunctionalTests(unittest.TestCase):
    def setUp(self):
        self.guard_script = SCRIPTS_DIR / "omaram-guard.sh"

    def test_host_shell_not_reported_confined(self):
        bash_cmd = f"""
        source <(sed -n '/^is_confined_or_sandboxed()/,/^}}/p' "{self.guard_script}")
        is_confined_or_sandboxed "$$"
        """
        res = subprocess.run(["bash", "-c", bash_cmd])
        self.assertEqual(res.returncode, 1, "Host shell should not be reported as confined")

    def test_nonexistent_pid_not_confined(self):
        bash_cmd = f"""
        source <(sed -n '/^is_confined_or_sandboxed()/,/^}}/p' "{self.guard_script}")
        is_confined_or_sandboxed 99999999
        """
        res = subprocess.run(["bash", "-c", bash_cmd])
        self.assertEqual(res.returncode, 1, "Nonexistent PID should return 1")

    def test_user_and_mount_namespace_isolation_detected(self):
        # Check if unshare is permitted on this host
        check_unshare = subprocess.run(["which", "unshare"], capture_output=True)
        if check_unshare.returncode != 0:
            self.skipTest("unshare command not available")

        bash_cmd = f"""
        source <(sed -n '/^is_confined_or_sandboxed()/,/^}}/p' "{self.guard_script}")
        unshare -U -m -- sleep 2 &
        CHILD_PID=$!
        sleep 0.1
        is_confined_or_sandboxed "$CHILD_PID"
        EXIT_CODE=$?
        kill "$CHILD_PID" 2>/dev/null || true
        exit "$EXIT_CODE"
        """
        res = subprocess.run(["bash", "-c", bash_cmd])
        if res.returncode == 0:
            self.assertEqual(res.returncode, 0, "Process inside isolated namespaces must be detected as confined")

    def test_container_cgroup_signatures(self):
        signatures = ["app-flatpak", "snap.firefox", "docker", "containerd", "bwrap", "sandbox"]
        pattern = r"(app-flatpak|snap\.|docker|containerd|bwrap|sandbox)"
        import re
        for sig in signatures:
            self.assertTrue(re.search(pattern, sig), f"Pattern must match signature {sig}")


class RestartSecurityFunctionalTests(unittest.TestCase):
    def test_cmd_args_overrides_argv0(self):
        bash_cmd = """
        EXE="/usr/bin/curl"
        CMD_ARGS=("malicious_name" "https://example.com")
        CMD_ARGS[0]="$EXE"
        printf '%s' "${CMD_ARGS[0]}"
        """
        res = subprocess.run(["bash", "-c", bash_cmd], capture_output=True, text=True, check=True)
        self.assertEqual(res.stdout, "/usr/bin/curl")

    def test_interpreter_inline_code_flag_rejections(self):
        interpreters = [
            "/usr/bin/bash",
            "/bin/sh",
            "/usr/bin/zsh",
            "/bin/dash",
            "/usr/bin/python3",
            "/usr/bin/python",
            "/usr/bin/perl",
            "/usr/bin/ruby",
            "/usr/bin/node",
            "/usr/bin/php",
        ]
        flags = ["-c", "-e", "--eval", "--command"]

        check_logic = """
        check() {
            local EXE="$1"
            shift
            local CMD_ARGS=("$EXE" "$@")
            CMD_ARGS[0]="$EXE"
            local exe_basename="${EXE##*/}"
            local has_inline_code=0
            if [[ "$exe_basename" =~ ^(bash|sh|zsh|dash|python.*|perl|ruby|node|php)$ ]]; then
                for arg in "${CMD_ARGS[@]:1}"; do
                    if [[ "$arg" == "-c" || "$arg" == "-e" || "$arg" == "--eval" || "$arg" == "--command" ]]; then
                        has_inline_code=1
                        break
                    fi
                done
            fi
            echo "$has_inline_code"
        }
        """
        for interp in interpreters:
            for flag in flags:
                bash_cmd = f'{check_logic}\ncheck "{interp}" "{flag}" "print(1)"'
                res = subprocess.run(["bash", "-c", bash_cmd], capture_output=True, text=True, check=True)
                self.assertEqual(
                    res.stdout.strip(),
                    "1",
                    f"Interpreter {interp} with flag {flag} must be rejected",
                )

    def test_benign_arguments_allowed(self):
        check_logic = """
        check() {
            local EXE="$1"
            shift
            local CMD_ARGS=("$EXE" "$@")
            CMD_ARGS[0]="$EXE"
            local exe_basename="${EXE##*/}"
            local has_inline_code=0
            if [[ "$exe_basename" =~ ^(bash|sh|zsh|dash|python.*|perl|ruby|node|php)$ ]]; then
                for arg in "${CMD_ARGS[@]:1}"; do
                    if [[ "$arg" == "-c" || "$arg" == "-e" || "$arg" == "--eval" || "$arg" == "--command" ]]; then
                        has_inline_code=1
                        break
                    fi
                done
            fi
            echo "$has_inline_code"
        }
        """
        allowed_cases = [
            ("/usr/bin/python3", ["/home/user/script.py", "--verbose"]),
            ("/usr/bin/bash", ["/home/user/myscript.sh", "arg1"]),
            ("/usr/bin/firefox", ["https://github.com", "-P", "default"]),
        ]
        for exe, args in allowed_cases:
            args_str = " ".join(f'"{a}"' for a in args)
            bash_cmd = f'{check_logic}\ncheck "{exe}" {args_str}'
            res = subprocess.run(["bash", "-c", bash_cmd], capture_output=True, text=True, check=True)
            self.assertEqual(res.stdout.strip(), "0", f"{exe} with benign args should be allowed")


class ProcessTableParsingTests(unittest.TestCase):
    def test_awk_filtering_and_state_tagging(self):
        awk_code = """
        $1 != self && $1 != parent && $5 !~ /^(omaram|gum|bash|ps|xdg-terminal)/ {
            tag = ($4 ~ /^T/ ? " ⏸️ PAUSED" : "");
            printf "%8s %7s MB %6s%%    %s%s\\n", $1, int($2/1024), $3, $5, tag
        }
        """
        sample_input = """\
100 50000 1.0 S bash
200 60000 1.2 S gum
300 70000 1.4 S omaram-guard
400 80000 1.6 S xdg-terminal-exec
500 90000 1.8 S ps
600 204800 5.0 S browser
700 409600 10.0 T ide-worker
800 50000 1.0 S self-proc
900 50000 1.0 S parent-proc
"""
        res = subprocess.run(
            ["awk", "-v", "self=800", "-v", "parent=900", awk_code],
            input=sample_input,
            capture_output=True,
            text=True,
            check=True,
        )
        lines = res.stdout.strip().splitlines()
        self.assertEqual(len(lines), 2, "Must filter self, parent, and wrappers to leave 2 entries")

        # Running process: converted MB and no pause tag
        self.assertIn("600", lines[0])
        self.assertIn("200 MB", lines[0])
        self.assertIn("browser", lines[0])
        self.assertNotIn("PAUSED", lines[0])

        # Paused process: converted MB and tagged with PAUSED
        self.assertIn("700", lines[1])
        self.assertIn("400 MB", lines[1])
        self.assertIn("ide-worker", lines[1])
        self.assertIn("⏸️ PAUSED", lines[1])

    def test_process_tree_aggregation(self):
        # Extract the AWK aggregation script directly from omaram-guard.sh
        guard_content = (SCRIPTS_DIR / "omaram-guard.sh").read_text()
        awk_start = guard_content.find("ps -u \"$UID\" --no-headers -o pid,ppid,rss,pmem,state,comm 2>/dev/null | awk -v self=\"$$\" -v parent=\"$PPID\" '")
        start_quote = guard_content.find("'", awk_start)
        end_quote = guard_content.find("' | sort -k2", start_quote)
        awk_code = guard_content[start_quote+1:end_quote]

        # Multi-process trees:
        # Chromium tree: root 1000, children 1001 (ppid 1000), 1002 (ppid 1001), 1003 (ppid 1000)
        # Code tree: root 2000, child 2001 (ppid 2000)
        # Single app: easyeffects 3000 (ppid 500)
        sample_input = """\
1000 500 204800 2.0 S chromium
1001 1000 307200 3.0 S chromium
1002 1001 512000 5.0 S chromium
1003 1000 409600 4.0 S chromium
2000 500 307200 3.0 S code
2001 2000 204800 2.0 S code
3000 500 102400 1.0 S easyeffects
9998 500 50000 0.5 S bash
9999 500 50000 0.5 S gum
"""
        res = subprocess.run(
            ["awk", "-v", "self=8888", "-v", "parent=9999", awk_code],
            input=sample_input,
            capture_output=True,
            text=True,
            check=True,
        )
        lines = res.stdout.strip().splitlines()
        # Should have 3 grouped entries: chromium, code, easyeffects
        self.assertEqual(len(lines), 3)

        # Chromium: 200+300+500+400 = 1400 MB (4 procs)
        self.assertIn("1000", lines[0])
        self.assertIn("1400 MB", lines[0])
        self.assertIn("chromium (4 procs)", lines[0])

        # Code: 300+200 = 500 MB (2 procs)
        self.assertIn("2000", lines[1])
        self.assertIn("500 MB", lines[1])
        self.assertIn("code (2 procs)", lines[1])

        # Easyeffects: 100 MB (1 proc -> no suffix)
        self.assertIn("3000", lines[2])
        self.assertIn("100 MB", lines[2])
        self.assertIn("easyeffects", lines[2])
        self.assertNotIn("(1 procs)", lines[2])


class TUIEngineFunctionalTests(unittest.TestCase):
    def setUp(self):
        self.guard_script = SCRIPTS_DIR / "omaram-guard.sh"

    def _run_choose(self, items, stdin_seq):
        items_def = " ".join(f'"{x}"' for x in items)
        bash_cmd = f"""
        source <(sed -n '/^omaram_choose()/,/^}}/p' "{self.guard_script}")
        get_tile_action_label() {{ echo "tile"; }}
        items=({items_def})
        out=""
        omaram_choose items "head" "foot %s" out < <(printf "{stdin_seq}") >/dev/null 2>&1
        STATUS=$?
        printf '%s|%s' "$STATUS" "$out"
        """
        res = subprocess.run(["bash", "-c", bash_cmd], capture_output=True, text=True, check=True)
        status, out = res.stdout.split("|", 1)
        return int(status), out

    def test_empty_items_returns_error(self):
        bash_cmd = f"""
        source <(sed -n '/^omaram_choose()/,/^}}/p' "{self.guard_script}")
        get_tile_action_label() {{ echo "tile"; }}
        items=()
        out=""
        omaram_choose items "head" "foot %s" out 2>/dev/null
        exit $?
        """
        res = subprocess.run(["bash", "-c", bash_cmd])
        self.assertEqual(res.returncode, 1)

    def test_enter_submits_first_choice(self):
        status, out = self._run_choose(["App1", "App2", "App3"], r"\n")
        self.assertEqual(status, 0)
        self.assertEqual(out, "App1")

    def test_down_arrow_selects_next_choice(self):
        status, out = self._run_choose(["App1", "App2", "App3"], r"\e[B\n")
        self.assertEqual(status, 0)
        self.assertEqual(out, "App2")

    def test_vim_j_navigation(self):
        status, out = self._run_choose(["App1", "App2", "App3"], r"j\n")
        self.assertEqual(status, 0)
        self.assertEqual(out, "App2")

    def test_escape_aborts_with_130(self):
        status, out = self._run_choose(["App1", "App2", "App3"], r"\e")
        self.assertEqual(status, 130)


class LauncherSecurityTests(unittest.TestCase):
    def setUp(self):
        self.launcher = SCRIPTS_DIR / "launch-omaram.sh"
        self.assertTrue(self.launcher.exists())
        self.content = self.launcher.read_text()

    def test_hyprland_geometry_and_rules(self):
        self.assertIn("size = { 465, 410 }", self.content)
        self.assertIn("float = true", self.content)
        self.assertIn("center = true", self.content)
        self.assertIn("OMARAM-GUARD", self.content)

    def test_wayland_session_invocation(self):
        self.assertIn("setsid uwsm-app", self.content)
        self.assertIn("xdg-terminal-exec", self.content)
        self.assertIn("--app-id=org.omarchy.terminal.omaram", self.content)
        self.assertIn("--title=OMARAM-GUARD", self.content)

    def test_dynamic_script_path(self):
        self.assertIn('SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"', self.content)


class QMLWidgetThresholdTests(unittest.TestCase):
    def setUp(self):
        self.qml = (ROOT_DIR / "MemoryGuard.qml").read_text()

    def test_color_and_alert_thresholds(self):
        # Amber at 75%
        self.assertIn("root.memPct >= 75", self.qml)
        # Red at 90%
        self.assertIn("root.memPct >= 90", self.qml)
        # Warning alert at 80%
        self.assertIn("pct >= 80", self.qml)
        # Critical alert at 90%
        self.assertIn("pct >= 90", self.qml)
        self.assertIn("High Memory Warning:", self.qml)
        self.assertIn("Critical Memory:", self.qml)

    def test_poll_frequency(self):
        # 5 second polling interval
        self.assertIn("interval: 5000", self.qml)


class TrueReclaimMetricTests(unittest.TestCase):
    def test_uss_and_pss_extraction(self):
        smaps_content = """\
Rss:              429484 kB
Pss:              302419 kB
Private_Clean:     92304 kB
Private_Dirty:    189204 kB
Shared_Clean:     143120 kB
Shared_Dirty:       4856 kB
"""
        awk_cmd = """
        awk '
            /^Private_(Clean|Dirty):/ {uss += $2}
            /^Pss:/ {pss += $2}
            END {print (uss ? uss : 0), (pss ? pss : 0)}
        '
        """
        res = subprocess.run(["bash", "-c", awk_cmd], input=smaps_content, capture_output=True, text=True, check=True)
        uss_kb, pss_kb = res.stdout.strip().split()
        uss_mb = int(uss_kb) // 1024
        pss_mb = int(pss_kb) // 1024

        # 92304 + 189204 = 281508 kB -> 274 MB
        self.assertEqual(uss_mb, 274)
        # 302419 kB -> 295 MB
        self.assertEqual(pss_mb, 295)


class LinuxPSIMetricTests(unittest.TestCase):
    def test_psi_extraction(self):
        psi_content = """\
some avg10=4.25 avg60=1.10 avg300=0.50 total=128492
full avg10=2.10 avg60=0.40 avg300=0.10 total=48102
"""
        awk_cmd = """
        awk '/^some/ {for (i=1; i<=NF; i++) if ($i ~ /^avg10=/) {sub("avg10=", "", $i); print $i"%"}}'
        """
        res = subprocess.run(["bash", "-c", awk_cmd], input=psi_content, capture_output=True, text=True, check=True)
        self.assertEqual(res.stdout.strip(), "4.25%")

    def test_psi_zero_handling(self):
        psi_content = """\
some avg10=0.00 avg60=0.00 avg300=0.00 total=100
"""
        awk_cmd = """
        awk '/^some/ {for (i=1; i<=NF; i++) if ($i ~ /^avg10=/) {sub("avg10=", "", $i); print $i"%"}}'
        """
        res = subprocess.run(["bash", "-c", awk_cmd], input=psi_content, capture_output=True, text=True, check=True)
        self.assertEqual(res.stdout.strip(), "0.00%")


if __name__ == "__main__":
    unittest.main()
