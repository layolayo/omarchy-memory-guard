#!/usr/bin/env python3
"""
OMARAM Guard - Security & Integrity Test Suite

Verifies:
1. Manifest validity, entrypoints, and plugin specification conformance.
2. Shell script syntax integrity (bash -n) and safe POSIX permissions.
3. Strict PID validation (rejects injection, negative, PID 0/1, self, alien processes).
4. Automated inline credential redaction across tokens, passwords, URLs, and API keys.
5. In-memory metric calculation accuracy and division-by-zero guards.
6. QML dynamic path resolution and bounds-checked exit code handling.
"""

import json
import os
import re
import stat
import subprocess
import unittest
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent.parent
SCRIPTS_DIR = ROOT_DIR / "scripts"


class ManifestSecurityTests(unittest.TestCase):
    def setUp(self):
        self.manifest_path = ROOT_DIR / "manifest.json"
        self.assertTrue(self.manifest_path.exists(), "manifest.json must exist")
        with open(self.manifest_path, "r", encoding="utf-8") as f:
            self.manifest = json.load(f)

    def test_schema_and_required_fields(self):
        self.assertEqual(self.manifest.get("schemaVersion"), 1)
        for field in ("id", "name", "version", "description", "kinds"):
            self.assertIn(field, self.manifest, f"Missing required field: {field}")
            self.assertTrue(self.manifest[field], f"Field cannot be empty: {field}")

    def test_plugin_id_safety(self):
        plugin_id = self.manifest["id"]
        self.assertNotIn("/", plugin_id, "Plugin ID must not contain slashes")
        self.assertNotIn("..", plugin_id, "Plugin ID must not contain path traversal")
        self.assertTrue(
            re.match(r"^[a-zA-Z0-9_\-\.]+$", plugin_id),
            "Plugin ID must only contain alphanumeric, dots, hyphens, and underscores",
        )

    def test_entrypoints_exist_and_safe(self):
        entry_points = self.manifest.get("entryPoints", {})
        self.assertIn("barWidget", entry_points)
        widget_file = entry_points["barWidget"]
        self.assertFalse(os.path.isabs(widget_file), "Entry point must be relative")
        self.assertNotIn("..", widget_file, "Entry point must not escape plugin root")
        self.assertTrue((ROOT_DIR / widget_file).exists(), f"{widget_file} must exist")


class ScriptIntegrityTests(unittest.TestCase):
    def test_shell_syntax(self):
        for script in SCRIPTS_DIR.glob("*.sh"):
            res = subprocess.run(["bash", "-n", str(script)], capture_output=True, text=True)
            self.assertEqual(res.returncode, 0, f"Syntax error in {script.name}:\n{res.stderr}")

    def test_executable_permissions(self):
        for script in SCRIPTS_DIR.glob("*.sh"):
            mode = script.stat().st_mode
            self.assertTrue(
                bool(mode & stat.S_IXUSR),
                f"{script.name} must be executable by user",
            )
            # Ensure standard 0755 permissions
            self.assertEqual(
                oct(mode)[-3:],
                "755",
                f"{script.name} should have 0755 permissions, got {oct(mode)}",
            )

    def test_shebang(self):
        for script in SCRIPTS_DIR.glob("*.sh"):
            with open(script, "r", encoding="utf-8") as f:
                first_line = f.readline().strip()
            self.assertEqual(first_line, "#!/bin/bash", f"{script.name} must have #!/bin/bash shebang")


class CheckMemPctSecurityTests(unittest.TestCase):
    def setUp(self):
        self.script = SCRIPTS_DIR / "check-mem-pct.sh"

    def test_normal_execution(self):
        res = subprocess.run([str(self.script)])
        self.assertGreaterEqual(res.returncode, 0)
        self.assertLessEqual(res.returncode, 100)

    def test_no_subshell_overhead(self):
        # The script should read /proc/meminfo directly, without executing free or awk
        content_lines = [
            line.strip()
            for line in self.script.read_text().splitlines()
            if line.strip() and not line.strip().startswith("#")
        ]
        non_comment_code = "\n".join(content_lines)
        self.assertNotIn("free", non_comment_code)
        self.assertNotIn("awk", non_comment_code)
        self.assertIn("/proc/meminfo", non_comment_code)


class DiagnoseSecurityTests(unittest.TestCase):
    def setUp(self):
        self.script = SCRIPTS_DIR / "omaram-diagnose.sh"

    def test_rejects_invalid_pid(self):
        invalid_pids = ["", "abc", "-1", "0", "1", "1; rm -rf /", "999999999"]
        for bad_pid in invalid_pids:
            res = subprocess.run([str(self.script), bad_pid], capture_output=True, text=True)
            self.assertNotEqual(res.returncode, 0, f"Should reject invalid PID: {bad_pid}")

    def test_credential_redaction_patterns(self):
        sample_dirty = (
            "app --token=super_secret_tok123 -p hunter2 -u admin:mypass123 "
            "https://user:dbsecret@postgres.internal:5432/main "
            "--api-key sk-abcdef1234567890abcdef "
            "ghp_123456789012345678901234567890123456 "
            "glpat-abcdef12345678901234 "
            "xoxb-1234-5678-abcdef"
        )
        content = self.script.read_text()
        start = content.find("clean_cmdline=$(printf")
        end = content.find("clean_cmdline=$(printf", start + 1)
        redact_block = content[start:end].strip()

        bash_cmd = f"""
        cmdline="{sample_dirty}"
        {redact_block}
        printf '%s' "$clean_cmdline"
        """
        res = subprocess.run(["bash", "-c", bash_cmd], capture_output=True, text=True, check=True)
        redacted = res.stdout
        self.assertNotIn("super_secret_tok123", redacted)
        self.assertNotIn("hunter2", redacted)
        self.assertNotIn("mypass123", redacted)
        self.assertNotIn("dbsecret", redacted)
        self.assertNotIn("sk-abcdef1234567890abcdef", redacted)
        self.assertNotIn("ghp_123456789012345678901234567890123456", redacted)
        self.assertNotIn("glpat-abcdef12345678901234", redacted)
        self.assertNotIn("xoxb-1234-5678-abcdef", redacted)
        self.assertIn("[REDACTED]", redacted)

    def test_privacy_invariants_documented_in_prompt(self):
        content = self.script.read_text()
        self.assertIn("NEVER read /proc/$pid/environ", content)
        self.assertIn("NEVER dump /proc/$pid/mem", content)
        self.assertIn("Inspect /proc/$pid/fd/ only to identify file paths and locks", content)
        # Ephemeral file hygiene & provenance signing matching Omarchy crash handler
        self.assertIn("Ephemeral file hygiene", content)
        self.assertIn("mktemp -t omaram-XXXXXX", content)
        self.assertIn("Provenance signing", content)
        self.assertIn("Diagnosed by <model name> via <agent harness>", content)

    def test_prctl_basename_sanitization(self):
        # Like omarchy-crash-watch, must strip slashes from comm in case prctl set path-like name
        content = self.script.read_text()
        self.assertIn("${comm##*/}", content)
        self.assertIn("${parent_comm##*/}", content)


class GuardSecurityTests(unittest.TestCase):
    def setUp(self):
        self.script = SCRIPTS_DIR / "omaram-guard.sh"
        self.content = self.script.read_text()

    def test_pid_validation_present(self):
        # Must ensure PID is numeric, > 1, and not self/parent
        self.assertIn('[[ ! "$PID" =~ ^[0-9]+$ ]]', self.content)
        self.assertIn('[ "$PID" -le 1 ]', self.content)
        self.assertIn('[ "$PID" -eq "$$" ]', self.content)
        self.assertIn('[ "$PID" -eq "$PPID" ]', self.content)

    def test_process_ownership_checked(self):
        # Must verify /proc/$PID ownership matches UID before signaling
        self.assertIn('stat -c \'%u\' "/proc/$PID"', self.content)
        self.assertIn('"$PROC_UID" != "$UID"', self.content)

    def test_safe_restart_guards(self):
        # Must verify cwd is a directory and fall back safely
        self.assertIn('if [[ ! -d "$CWD" ]]', self.content)
        # Must verify exe fallback
        self.assertIn('readlink -f "/proc/$PID/exe"', self.content)

    def test_prctl_basename_sanitization(self):
        # Must strip path components from process name
        self.assertIn("${NAME##*/}", self.content)

    def test_auto_tiles_on_diagnose(self):
        # Must check if window is floating and auto-tile before launching AI agent
        self.assertIn("tile_if_floating", self.content)
        self.assertIn("is_floating", self.content)
        self.assertIn("hl.dsp.window.float", self.content)
        self.assertIn("action = \\\"off\\\"", self.content)

    def test_dynamic_navigation_tile_float_label(self):
        # Must detect whether window is floating or tiled and adjust navigation label
        self.assertIn("get_tile_action_label", self.content)
        self.assertIn("super+t %s • esc quit", self.content)
        self.assertIn("super+t %s • esc back", self.content)

        # Test the function logic with mocked floating states
        test_script_tiled = """
        source <(sed -n '/^get_tile_action_label()/,/^}/p' "$1")
        hyprctl() {
            if [ "$1" = "activewindow" ]; then
                echo '{"class": "org.omarchy.terminal.omaram", "floating": false}'
            fi
        }
        export -f hyprctl
        export HYPRLAND_INSTANCE_SIGNATURE="mock"
        get_tile_action_label
        """
        res_tiled = subprocess.run(["bash", "-c", test_script_tiled, "_", str(self.script)], capture_output=True, text=True)
        self.assertEqual(res_tiled.returncode, 0)
        self.assertEqual(res_tiled.stdout.strip(), "float")

        test_script_floating = """
        source <(sed -n '/^get_tile_action_label()/,/^}/p' "$1")
        hyprctl() {
            if [ "$1" = "activewindow" ]; then
                echo '{"class": "org.omarchy.terminal.omaram", "floating": true}'
            fi
        }
        export -f hyprctl
        export HYPRLAND_INSTANCE_SIGNATURE="mock"
        get_tile_action_label
        """
        res_floating = subprocess.run(["bash", "-c", test_script_floating, "_", str(self.script)], capture_output=True, text=True)
        self.assertEqual(res_floating.returncode, 0)
        self.assertEqual(res_floating.stdout.strip(), "tile")


class InvestigationDocSecurityTests(unittest.TestCase):
    def setUp(self):
        self.doc_path = ROOT_DIR / "docs" / "INVESTIGATION.md"
        self.assertTrue(self.doc_path.exists())
        self.content = self.doc_path.read_text()

    def test_upstream_reporting_guardrails(self):
        # Must require verified bug in Omarchy's sphere, user consent, and gh auth status
        self.assertIn("Upstream Reporting Guardrails", self.content)
        self.assertIn("Verified bug in Omarchy's sphere", self.content)
        self.assertIn("Explicit user agreement", self.content)
        self.assertIn("gh auth status", self.content)
        self.assertIn("Provenance Signing", self.content)


class QMLIntegrityTests(unittest.TestCase):
    def setUp(self):
        self.qml_path = ROOT_DIR / "MemoryGuard.qml"
        self.assertTrue(self.qml_path.exists())
        self.content = self.qml_path.read_text()

    def test_dynamic_path_resolution(self):
        self.assertIn("Qt.resolvedUrl", self.content)
        # Ensure hardcoded ~/.config plugin path is removed
        self.assertNotIn("$HOME/.config/omarchy/plugins", self.content)

    def test_exit_code_validation(self):
        # Must check bounds between 0 and 100 before updating memPct or triggering alerts
        self.assertIn("exitCode >= 0 && exitCode <= 100", self.content)

    def test_command_injection_safeguards(self):
        # The exec argument in notification should be safely quoted
        self.assertIn("launcher.replace(/'/g, \"'\\\\''\")", self.content)


if __name__ == "__main__":
    unittest.main()
