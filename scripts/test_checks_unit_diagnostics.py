#!/usr/bin/env python3
"""Causal diagnostic controls using actual owned subprocesses; never signals foreign PIDs."""
import errno
import importlib.util
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("unit_command", Path(__file__).with_name("checks-unit-command.py"))
WRAPPER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(WRAPPER)
REAL_POPEN, REAL_RUN, REAL_KILLPG = subprocess.Popen, subprocess.run, os.killpg


def drain(child):
    if child.poll() is None:
        child.terminate()
        try: child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            child.kill(); child.wait(timeout=5)
    else:
        child.wait()


class DiagnosticCaptureTests(unittest.TestCase):
    def test_permission_denied_signal_still_reports_and_reaps_owned_child(self):
        with tempfile.TemporaryDirectory(prefix="unit-diagnostic-eperm-") as temporary:
            children, waits = [], []
            def spawn(*args, **kwargs):
                child = REAL_POPEN(*args, **kwargs); children.append(child)
                original_wait = child.wait
                def wait(timeout=None):
                    waits.append(timeout); return original_wait(timeout=timeout)
                child.wait = wait
                return child
            def signal_group(group, kind):
                self.assertEqual(group, children[0].pid)
                if kind == signal.SIGKILL:
                    raise PermissionError(errno.EPERM, "owned fixture denied KILL")
                REAL_KILLPG(group, kind)
            result, failure = None, None
            try:
                with patch.object(WRAPPER.subprocess, "Popen", side_effect=spawn), \
                     patch.object(WRAPPER.os, "killpg", side_effect=signal_group), \
                     patch.object(WRAPPER, "sample_owned", return_value=[]), \
                     patch.object(WRAPPER, "ceiling", return_value=0.1), \
                     patch.dict(os.environ, {"CHECKS_LOG_DIR": temporary}), \
                     patch.object(sys, "argv", ["checks-unit-command", sys.executable, "-c", "import signal; signal.pause()"]):
                    try: result = WRAPPER.main()
                    except PermissionError as error: failure = error
                import json
                evidence = json.loads((Path(temporary) / "unit-watchdog.json").read_text())
                self.assertIsNone(failure, "signal failure must become honest metadata, not a traceback")
                self.assertEqual(result, 1)
                self.assertIn({"signal": "SIGKILL", "errno": errno.EPERM}, evidence.get("signalErrors", []))
                self.assertIn(5, waits, "actual owned child receives a bounded reap attempt")
            finally:
                for child in children: drain(child)

    def test_actual_sampler_can_finish_symbol_processing_after_five_seconds(self):
        with tempfile.TemporaryDirectory(prefix="unit-diagnostic-sample-") as temporary:
            root = Path(temporary); gate = root / "processing-gate"; os.mkfifo(gate)
            sampler = root / "sampler.py"
            sampler.write_text("import pathlib,sys\nprint('Sampling completed, processing symbols...',flush=True)\nwith open(sys.argv[1]) as gate: gate.read()\npathlib.Path(sys.argv[2]).write_text('owned main and worker stack fixture\\n')\n")
            target = REAL_POPEN([sys.executable, "-c", "import signal; signal.pause()"], start_new_session=True)
            release_fired = threading.Event()
            def release():
                release_fired.set()
                try:
                    fd = os.open(gate, os.O_WRONLY | os.O_NONBLOCK)
                    try: os.write(fd, b"symbol processing complete")
                    finally: os.close(fd)
                except OSError: pass
            timer = threading.Timer(6, release)
            sample_calls = []
            def run(args, **kwargs):
                if args[0] == "/usr/bin/sample":
                    self.assertEqual(int(args[1]), target.pid)
                    sample_calls.append(target.pid)
                    timer.start()
                    output = args[args.index("-file") + 1]
                    return REAL_RUN([sys.executable, str(sampler), str(gate), output], **kwargs)
                return REAL_RUN(args, **kwargs)
            try:
                with patch.object(WRAPPER.subprocess, "run", side_effect=run), patch.object(WRAPPER.sys, "platform", "darwin"):
                    samples = WRAPPER.sample_owned(target.pid, root)
                self.assertEqual(sample_calls, [target.pid], "actual owned candidate is sampled")
                self.assertEqual(samples, ["unit-stack-" + str(target.pid) + ".txt"])
                self.assertEqual((root / samples[0]).read_text(), "owned main and worker stack fixture\n")
                self.assertTrue(release_fired.is_set())
            finally:
                timer.cancel()
                if timer.ident is not None: timer.join(timeout=7)
                drain(target)


if __name__ == "__main__":
    unittest.main()
