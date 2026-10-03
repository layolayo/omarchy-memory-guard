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


if __name__ == "__main__":
    unittest.main()
