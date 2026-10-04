#!/usr/bin/env python3
"""Exercise the actual runner with owned fake commands and a gated unit lane.

No builds, sockets, Gateway traffic or shared defaults. The runner source is copied unchanged
into a scratch tree only so its existing repository-relative paths remain real.
"""
import argparse
import json
import os
from pathlib import Path
import selectors
import shutil
import signal
import subprocess
import sys
import tempfile
import time

FAKE = r'''#!/usr/bin/env python3
import os, signal, sys
from pathlib import Path
root = Path(os.environ["CHECKS_FIXTURE_ROOT"])
name = Path(sys.argv[0]).name
if name == "swift":
    if "--show-bin-path" in sys.argv:
        print(root / "bin"); sys.exit(0)
    if "--parallel" in sys.argv:
        (root / "unit-admitted").touch()
        print("PRIVATE_FIXTURE_LOG_CONTENT", flush=True)
        with open(root / "unit-gate", "r") as gate: gate.read()
    print("fixture unit complete"); sys.exit(0)
if name == "node":
    port = os.environ["PORT"]
    (root / "mocks" / (port + ".pid")).write_text(str(os.getpid()))
    def stop(*_):
        (root / "mocks" / (port + ".stopped")).touch()
        sys.exit(0)
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    while True: signal.pause()
if name == "nc":
    sys.exit(0 if (root / "mocks" / (sys.argv[-1] + ".pid")).exists() else 1)
mode = next((x for x in sys.argv[1:] if x.startswith("--demo-") or x.startswith("--live-")), "offline")
(root / "completed" / mode).touch()
print("PRIVATE_FIXTURE_LOG_CONTENT")
print("fixture checks complete")
sys.exit(7 if mode == os.environ.get("CHECKS_FIXTURE_FAILURE") else 0)
'''


def wait_until(predicate, timeout=5):
    deadline = time.monotonic() + timeout
    while not predicate():
        if time.monotonic() >= deadline:
            raise AssertionError("owned fake command admission/completion did not arrive")
        time.sleep(0.01)


def execute(require_progress, fail_lane):
    source = Path(__file__).resolve().with_name("run-checks.sh")
    with tempfile.TemporaryDirectory(prefix="pincer-checks-progress-") as temporary:
        root = Path(temporary)
        (root / "scripts").mkdir()
        shutil.copyfile(source, root / "scripts" / "run-checks.sh")
        (root / "mock-gateway" / "node_modules").mkdir(parents=True)
        for directory in ("bin", "fake", "mocks", "completed", "logs"):
            (root / directory).mkdir()
        for name in ("swift", "node", "nc"):
            command = root / "fake" / name
            command.write_text(FAKE); command.chmod(0o755)
        command = root / "bin" / "PincerChecks"
        command.write_text(FAKE); command.chmod(0o755)
        os.mkfifo(root / "unit-gate")
        env = dict(os.environ, PATH=str(root / "fake") + os.pathsep + os.environ["PATH"],
                   CHECKS_FIXTURE_ROOT=str(root), CHECKS_LOG_DIR=str(root / "logs"),
                   CHECKS_PORT_BASE="29801", CHECKS_PROGRESS_INTERVAL="0.1")
        if fail_lane: env["CHECKS_FIXTURE_FAILURE"] = "--demo-extras"
        process = subprocess.Popen(["/bin/bash", str(root / "scripts" / "run-checks.sh")],
                                   env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   start_new_session=True, bufsize=0)
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        before_release = bytearray()
        released = False
        try:
            wait_until(lambda: (root / "unit-admitted").exists())
            wait_until(lambda: len(list((root / "completed").iterdir())) == 9)
            # Success is an actual output event while the unit command is held, never a sleep.
            if require_progress:
                deadline = time.monotonic() + 3
                while time.monotonic() < deadline:
                    for key, _ in selector.select(timeout=0.05):
                        chunk = os.read(key.fd, 4096)
                        if not chunk: break
                        before_release.extend(chunk)
                    if len(before_release) > 8192: break
                    if b"[checks progress]" in before_release and b"unit-tests" in before_release: break
            with open(root / "unit-gate", "w") as gate: gate.write("release")
            released = True
            after_release, _ = process.communicate(timeout=10)
            wait_until(lambda: len(list((root / "mocks").glob("*.stopped"))) == 6)
            output = bytes(before_release) + after_release
            text = output.decode("utf-8", errors="replace")
            progress_lines = [line for line in bytes(before_release).splitlines() if b"[checks progress]" in line]
            result = {
                "pendingVisible": bool(progress_lines) and any(b"unit-tests" in line and b"pending" in line for line in progress_lines),
                "pendingOutputBounded": len(before_release) <= 8192 and all(len(line) <= 512 for line in progress_lines),
                "pendingContainsNoLogPayload": b"PRIVATE_FIXTURE_LOG_CONTENT" not in before_release,
                "allLanesCompleted": "Lane               Result" in text and "perf-tests" in text and "perf-smoke" in text,
                "statusPreserved": process.returncode == (1 if fail_lane else 0),
                "allMocksCleaned": len(list((root / "mocks").glob("*.stopped"))) == 6,
            }
            assertions = ["pendingOutputBounded", "pendingContainsNoLogPayload", "allLanesCompleted", "statusPreserved", "allMocksCleaned"]
            if require_progress: assertions.append("pendingVisible")
            print(json.dumps(result, sort_keys=True))
            failed = [key for key in assertions if not result[key]]
            if failed:
                print("actual runner fixture failed: " + ", ".join(failed), file=sys.stderr)
                return 1
            return 0
        finally:
            selector.close()
            if process.poll() is None:
                if not released:
                    try:
                        descriptor = os.open(root / "unit-gate", os.O_WRONLY | os.O_NONBLOCK)
                        os.write(descriptor, b"cleanup"); os.close(descriptor)
                    except OSError: pass
                try: os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError: pass
                try: process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL); process.wait()
            # Only task-owned fake processes are eligible for cleanup.
            for file in (root / "mocks").glob("*.pid"):
                try: os.kill(int(file.read_text()), signal.SIGTERM)
                except ProcessLookupError: pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--completed-control", action="store_true")
    parser.add_argument("--failed-lane-control", action="store_true")
    args = parser.parse_args()
    return execute(not (args.completed_control or args.failed_lane_control), args.failed_lane_control)


if __name__ == "__main__":
    sys.exit(main())
