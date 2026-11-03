#!/usr/bin/env python3
"""Exercise watchdog restoration using fake tools. Never invokes real pmset/root."""
import ast
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Scripts/clamshell-session.sh"
EMBEDDED = ROOT / "Packages/KYAApplicationSupport/Sources/KYAApplicationSupport/KYAClamshellWatchdog.inc"


def embedded_source():
    return "".join(ast.literal_eval(line) for line in EMBEDDED.read_text().splitlines() if line.startswith('"'))


class WatchdogTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="kya-watchdog-test-")
        self.root = Path(self.temp.name)
        self.session = self.root / "session"
        self.session.mkdir()
        self.state = self.root / "state"
        self.state.write_text("0")
        self.owner = self.root / "owner"
        self.owner.write_text("owner-start-one\n")
        self.battery = self.root / "battery"
        self.battery.write_text("Now drawing from 'AC Power'\n -InternalBattery-0 8%; charging;\n")
        self.log = self.root / "writes"
        self.failure = self.root / "failure"
        self.failure.write_text("")
        self.pmset = self.root / "fake-pmset"
        self.pmset.write_text("#!/bin/sh\n" + f"state={shlex.quote(str(self.state))}\nlog={shlex.quote(str(self.log))}\nfailure={shlex.quote(str(self.failure))}\nbattery={shlex.quote(str(self.battery))}\n" + '''
if [ "$1" = -g ]; then
    if [ "$#" = 2 ] && [ "$2" = batt ]; then cat "$battery"; exit 0; fi
    printf 'System-wide power settings:\n SleepDisabled  %s\n' "$(cat "$state")"
    exit 0
fi
[ "$1" = -a ] && [ "$2" = disablesleep ] || exit 65
printf '%s\n' "$3" >> "$log"
mode=$(cat "$failure")
if [ "$3" = 1 ] && [ "$mode" = verify ]; then exit 0; fi
if [ "$3" = 0 ] && [ "$mode" = restore ]; then exit 1; fi
printf '%s' "$3" > "$state"
if [ "$3" = 1 ] && [ "$mode" = enable ]; then exit 1; fi
exit 0
''')
        self.pmset.chmod(0o700)
        self.ps = self.root / "fake-ps"
        self.ps.write_text("#!/bin/sh\ncat " + shlex.quote(str(self.owner)) + "\n")
        self.ps.chmod(0o700)
        script = SOURCE.read_text().replace("PMSET=/usr/bin/pmset", "PMSET=" + shlex.quote(str(self.pmset)))
        script = script.replace("PS=/bin/ps", "PS=" + shlex.quote(str(self.ps)))
        script = script.replace("LOCK_DIR=/var/run/com.webfooo.KeepingYouAwake.clamshell", "LOCK_DIR=" + shlex.quote(str(self.root / "global-lock")))
        script = script.replace("RESTORE_ATTEMPTS=30", "RESTORE_ATTEMPTS=2")
        script = script.replace("INTERVAL=2", "INTERVAL=0.05").replace("HEARTBEAT_TIMEOUT=60", "HEARTBEAT_TIMEOUT=2")
        self.script = self.root / "watchdog.sh"
        self.script.write_text(script)
        self.process = None

    def tearDown(self):
        if self.process is not None and self.process.poll() is None:
            (self.session / "stop").touch()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.temp.cleanup()

    def launch(self):
        (self.session / "heartbeat").touch()
        self.process = subprocess.Popen(["/bin/sh", str(self.script), str(self.session), "1234", "owner-start-one"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def wait_marker(self, name, timeout=5):
        marker = self.session / name
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if marker.exists() and marker.read_text().strip():
                return marker.read_text().strip()
            time.sleep(0.02)
        self.fail(f"{name} not written; process={self.process.poll()}")

    def writes(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def assert_restored(self, reason):
        self.assertEqual(self.wait_marker("done"), reason)
        self.process.wait(timeout=3)
        self.assertEqual(self.state.read_text(), "0")
        self.assertEqual(self.writes(), ["1", "0"])

    def test_embedded_script_matches_source(self):
        self.assertEqual(embedded_source(), SOURCE.read_text())

    def test_enable_and_stop(self):
        self.launch()
        self.assertEqual(int(self.wait_marker("ready")), self.process.pid)
        self.assertEqual(self.state.read_text(), "1")
        (self.session / "stop").touch()
        self.assert_restored("stopped")

    def test_owner_gone(self):
        self.launch()
        self.wait_marker("ready")
        self.owner.unlink()
        self.assert_restored("owner-gone")

    def test_reused_pid_is_not_same_owner(self):
        self.launch()
        self.wait_marker("ready")
        self.owner.write_text("owner-start-two\n")
        self.assert_restored("owner-gone")

    def test_preexisting_setting_not_owned_or_changed(self):
        self.state.write_text("1")
        self.launch()
        self.assertEqual(self.wait_marker("done"), "already-disabled")
        self.assertEqual(self.state.read_text(), "1")
        self.assertEqual(self.writes(), [])
        self.assertFalse((self.session / "ready").exists())

    def test_failed_enable_restores_even_if_command_wrote(self):
        self.failure.write_text("enable")
        self.launch()
        self.assert_restored("error:enable")

    def test_failed_verification_restores(self):
        self.failure.write_text("verify")
        self.launch()
        self.assert_restored("error:verify")

    def test_low_battery_restores_without_app(self):
        self.battery.write_text("Now drawing from 'Battery Power'\n -InternalBattery-0 10%; discharging;\n")
        self.launch()
        self.assert_restored("low-battery")

    def test_low_percentage_on_ac_does_not_stop(self):
        self.launch()
        self.wait_marker("ready")
        time.sleep(0.15)
        self.assertIsNone(self.process.poll())
        (self.session / "stop").touch()
        self.assert_restored("stopped")

    def test_heartbeat_timeout_restores(self):
        self.launch()
        self.wait_marker("ready")
        self.assert_restored("heartbeat-expired")

    def test_external_change_ends_session_without_overwriting(self):
        self.launch()
        self.wait_marker("ready")
        self.state.write_text("0")
        self.assertEqual(self.wait_marker("done"), "external-change")
        self.process.wait(timeout=3)
        self.assertEqual(self.writes(), ["1"])

    def test_restore_failure_reports_unrestored_state(self):
        self.failure.write_text("restore")
        self.launch()
        self.wait_marker("ready")
        (self.session / "stop").touch()
        self.assertEqual(self.wait_marker("done"), "error:restore")
        self.process.wait(timeout=3)
        self.assertEqual(self.state.read_text(), "1")
        self.assertEqual(self.writes(), ["1", "0", "0"])

    def test_global_lock_refuses_second_session(self):
        self.launch()
        self.wait_marker("ready")
        other = self.root / "other-session"
        other.mkdir()
        (other / "heartbeat").touch()
        result = subprocess.run(["/bin/sh", str(self.script), str(other), "5678", "owner-start-one"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((other / "done").read_text().strip(), "already-running")
        self.assertTrue((self.root / "global-lock").exists())
        self.assertEqual(self.writes(), ["1"])
        (self.session / "stop").touch()
        self.assert_restored("stopped")
        self.assertFalse((self.root / "global-lock").exists())

    def test_foreign_lock_is_not_removed(self):
        lock = self.root / "global-lock"
        lock.mkdir()
        (lock / "owner").write_text("different-owner")
        self.launch()
        self.assertEqual(self.wait_marker("done"), "already-running")
        self.process.wait(timeout=3)
        self.assertEqual((lock / "owner").read_text(), "different-owner")
        self.assertEqual(self.writes(), [])

    def test_exit_signal_restores(self):
        self.launch()
        self.wait_marker("ready")
        self.process.terminate()
        self.assert_restored("signal")


if __name__ == "__main__":
    if "--embed" in os.sys.argv:
        EMBEDDED.write_text("// Generated from Scripts/clamshell-session.sh; regression tests verify synchronization.\nstatic const char * const KYAClamshellWatchdogScript =\n" + "".join(json.dumps(line, ensure_ascii=True) + "\n" for line in SOURCE.read_text().splitlines(keepends=True)) + ";\n")
    else:
        unittest.main(verbosity=2)
