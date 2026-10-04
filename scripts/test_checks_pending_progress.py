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
        print("◇ Test heldUnitFixture() started.", flush=True)
        print("PRIVATE_FIXTURE_LOG_CONTENT", flush=True)
        with open(root / "unit-gate", "r") as gate: gate.read()
    print("fixture unit complete"); sys.exit(0)
if name == "node":
    if any(x.endswith("checks-pending-progress.mjs") for x in sys.argv[1:]):
        with open(root / "progress-readers", "a") as readers: readers.write(str(os.getpid()) + "\n")
        os.execv(os.environ["CHECKS_FIXTURE_REAL_NODE"], [os.environ["CHECKS_FIXTURE_REAL_NODE"]] + sys.argv[1:])
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


def execute(require_progress, fail_lane, require_identity=False, interrupt=False, stale_markers=False):
    source = Path(__file__).resolve().with_name("run-checks.sh")
    with tempfile.TemporaryDirectory(prefix="pincer-checks-progress-") as temporary:
        root = Path(temporary)
        (root / "scripts").mkdir()
        shutil.copyfile(source, root / "scripts" / "run-checks.sh")
        helper = source.with_name("checks-pending-progress.mjs")
        if helper.exists(): shutil.copyfile(helper, root / "scripts" / helper.name)
        (root / "mock-gateway" / "node_modules").mkdir(parents=True)
        for directory in ("bin", "fake", "mocks", "completed", "logs"):
            (root / directory).mkdir()
        for name in ("swift", "node", "nc"):
            command = root / "fake" / name
            command.write_text(FAKE); command.chmod(0o755)
        command = root / "bin" / "PincerChecks"
        command.write_text(FAKE); command.chmod(0o755)
        if stale_markers:
            for lane in ("unit-tests", "self-checks", "demo-core", "demo-extras", "live-core", "live-extras", "live-no-usage", "live-no-reply-to", "live-reconnect", "live-no-session-reactions", "perf-smoke", "perf-tests"):
                (root / "logs" / (lane + ".seconds")).write_text("999")
            (root / "logs" / "unrelated.seconds").write_text("keep unrelated marker")
        os.mkfifo(root / "unit-gate")
        env = dict(os.environ, PATH=str(root / "fake") + os.pathsep + os.environ["PATH"],
                   CHECKS_FIXTURE_ROOT=str(root), CHECKS_FIXTURE_REAL_NODE=shutil.which("node") or "", CHECKS_LOG_DIR=str(root / "logs"),
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
            stale_unit_marker_cleared = not (root / "logs" / "unit-tests.seconds").exists()
            # Success is an actual output event while the unit command is held, never a sleep.
            if require_progress:
                deadline = time.monotonic() + 3
                while time.monotonic() < deadline:
                    for key, _ in selector.select(timeout=0.05):
                        chunk = os.read(key.fd, 4096)
                        if not chunk: break
                        before_release.extend(chunk)
                    if len(before_release) > 8192: break
                    if b"[checks progress]" in before_release and b"unit-tests" in before_release:
                        if not require_identity or b"heldUnitFixture()" in before_release: break
            if interrupt:
                process.terminate()  # Only the actual task-owned script, while its unit lane is held.
            else:
                with open(root / "unit-gate", "w") as gate: gate.write("release")
                released = True
            after_release, _ = process.communicate(timeout=10)
            wait_until(lambda: len(list((root / "mocks").glob("*.stopped"))) == 6)
            output = bytes(before_release) + after_release
            text = output.decode("utf-8", errors="replace")
            progress_lines = [line for line in bytes(before_release).splitlines() if b"[checks progress]" in line]
            reader_file = root / "progress-readers"
            reader_alive = False
            reader_count = 0
            if reader_file.exists():
                readers = reader_file.read_text().splitlines()
                reader_count = len(readers)
                for pid in readers:
                    try: os.kill(int(pid), 0); reader_alive = True
                    except ProcessLookupError: pass
            result = {
                "staleOwnedMarkerCleared": stale_unit_marker_cleared,
                "unrelatedMarkerPreserved": not stale_markers or (root / "logs" / "unrelated.seconds").read_text() == "keep unrelated marker",
                "pendingVisible": bool(progress_lines) and any(b"unit-tests" in line and b"pending" in line for line in progress_lines),
                "safeUnitIdentityVisible": any(b"heldUnitFixture()" in line for line in progress_lines),
                "pendingOutputBounded": len(before_release) <= 8192 and all(len(line) <= 512 for line in progress_lines),
                "pendingContainsNoLogPayload": b"PRIVATE_FIXTURE_LOG_CONTENT" not in before_release,
                "allLanesCompleted": "Lane               Result" in text and "perf-tests" in text and "perf-smoke" in text,
                "statusPreserved": process.returncode in (-signal.SIGTERM, 128 + signal.SIGTERM) if interrupt else process.returncode == (1 if fail_lane else 0),
                "allMocksCleaned": len(list((root / "mocks").glob("*.stopped"))) == 6,
                "progressReaderCleaned": not reader_alive,
                "soloPerformanceHasNoReader": reader_count == 1 if helper.exists() else reader_count == 0,
            }
            assertions = ["pendingOutputBounded", "pendingContainsNoLogPayload", "allLanesCompleted", "statusPreserved", "allMocksCleaned", "progressReaderCleaned", "soloPerformanceHasNoReader"]
            if interrupt: assertions.remove("allLanesCompleted")
            if require_progress: assertions.append("pendingVisible")
            if require_identity: assertions.append("safeUnitIdentityVisible")
            if stale_markers: assertions.extend(["staleOwnedMarkerCleared", "unrelatedMarkerPreserved"])
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
            # Interruption can leave the owned held unit child alive; kill only this process group.
            try: os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError: pass
            # Only task-owned fake processes are eligible for cleanup.
            for file in (root / "mocks").glob("*.pid"):
                if file.with_suffix(".stopped").exists(): continue
                try: os.kill(int(file.read_text()), signal.SIGTERM)
                except ProcessLookupError: pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--completed-control", action="store_true")
    parser.add_argument("--failed-lane-control", action="store_true")
    parser.add_argument("--require-safe-identity", action="store_true")
    parser.add_argument("--interrupt-control", action="store_true")
    parser.add_argument("--stale-completion-control", action="store_true")
    args = parser.parse_args()
    return execute(not (args.completed_control or args.failed_lane_control), args.failed_lane_control, args.require_safe_identity, args.interrupt_control, args.stale_completion_control)


if __name__ == "__main__":
    sys.exit(main())
