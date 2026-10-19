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
    if "test" in sys.argv:
        with open(root / "swift-test-calls", "a") as calls: calls.write("x\n")
    print("◇ Test run started.", flush=True)
    if "--parallel" in sys.argv and "CHECKS_FIXTURE_NOGATE" in os.environ:
        pass
    elif "--parallel" in sys.argv:
        (root / "unit-admitted").touch()
        print("◇ Test heldUnitFixture() started.", flush=True)
        print("PRIVATE_FIXTURE_LOG_CONTENT", flush=True)
        with open(root / "unit-gate", "r") as gate: gate.read()
    print("✔ Test run with 1 test in 1 suite passed after 0.1 seconds.")
    print("fixture unit complete"); sys.exit(0)
if name == "node":
    if any(x.endswith("checks-pending-progress.mjs") for x in sys.argv[1:]):
        with open(root / "progress-readers", "a") as readers: readers.write(str(os.getpid()) + "\n")
        with open(root / "progress-stdout", "a") as stdout: stdout.write(str(os.fstat(1).st_ino) + "\n")
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
        env.pop("CHECKS_SHARD", None)  # a CI shard's own setting must not narrow the runner under test
        if fail_lane: env["CHECKS_FIXTURE_FAILURE"] = "--demo-extras"
        # The runner's own pipe, so the fixture knows which stdout the progress helper must not share:
        # Node makes a pipe non-blocking for every writer, and the runner's output then fails with EAGAIN.
        read_end, write_end = os.pipe()
        runner_stdout = os.fstat(write_end).st_ino
        process = subprocess.Popen(["/bin/bash", str(root / "scripts" / "run-checks.sh")],
                                   env=env, stdout=write_end, stderr=subprocess.STDOUT,
                                   start_new_session=True, bufsize=0)
        os.close(write_end)
        selector = selectors.DefaultSelector()
        selector.register(read_end, selectors.EVENT_READ)

        def read_to_end(timeout):
            deadline, output = time.monotonic() + timeout, bytearray()
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0: raise subprocess.TimeoutExpired(process.args, timeout)
                if selector.select(timeout=remaining):
                    chunk = os.read(read_end, 65536)
                    if not chunk: break
                    output.extend(chunk)
            process.wait(timeout=max(deadline - time.monotonic(), 0.1))
            return bytes(output)
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
            after_release = read_to_end(10)
            wait_until(lambda: len(list((root / "mocks").glob("*.stopped"))) == 6)
            output = bytes(before_release) + after_release
            text = output.decode("utf-8", errors="replace")
            progress_lines = [line for line in bytes(before_release).splitlines() if b"[checks progress]" in line]
            reader_file = root / "progress-readers"
            reader_alive = False
            stdout_file = root / "progress-stdout"
            progress_stdout = stdout_file.read_text().splitlines() if stdout_file.exists() else []
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
                "progressHasItsOwnStdout": str(runner_stdout) not in progress_stdout,
            }
            assertions = ["pendingOutputBounded", "pendingContainsNoLogPayload", "allLanesCompleted", "statusPreserved", "allMocksCleaned", "progressReaderCleaned", "soloPerformanceHasNoReader", "progressHasItsOwnStdout"]
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
            os.close(read_end)
            if process.poll() is None:
                if not released:
                    try:
                        descriptor = os.open(root / "unit-gate", os.O_WRONLY | os.O_NONBLOCK)
                        os.write(descriptor, b"cleanup"); os.close(descriptor)
                    except OSError: pass
                try: os.killpg(process.pid, signal.SIGTERM)
                except (ProcessLookupError, PermissionError): pass
                try: process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL); process.wait()
            # Interruption can leave the owned held unit child alive; kill only this process group.
            try: os.killpg(process.pid, signal.SIGTERM)
            except (ProcessLookupError, PermissionError): pass
            # Only task-owned fake processes are eligible for cleanup.
            for file in (root / "mocks").glob("*.pid"):
                if file.with_suffix(".stopped").exists(): continue
                try: os.kill(int(file.read_text()), signal.SIGTERM)
                except ProcessLookupError: pass


ALL_LANES = ["unit-tests", "self-checks", "demo-core", "demo-extras", "live-core", "live-extras", "live-no-usage",
             "live-no-reply-to", "live-reconnect", "live-no-session-reactions", "perf-smoke", "perf-tests"]
UNIT_LANES = ["unit-tests", "perf-tests"]
CHECKS_LANES = [lane for lane in ALL_LANES if lane not in UNIT_LANES]


def execute_shard(shard, lean=False):
    """Runs the real script with CHECKS_SHARD; returns (exit code, output, lanes, mock count, swift test calls)."""
    source = Path(__file__).resolve().with_name("run-checks.sh")
    with tempfile.TemporaryDirectory(prefix="pincer-checks-shard-") as temporary:
        root = Path(temporary)
        (root / "scripts").mkdir()
        shutil.copyfile(source, root / "scripts" / "run-checks.sh")
        helper = source.with_name("checks-pending-progress.mjs")
        if helper.exists(): shutil.copyfile(helper, root / "scripts" / helper.name)
        for directory in ("bin", "fake", "mocks", "completed", "logs"):
            (root / directory).mkdir()
        if not lean:
            (root / "mock-gateway" / "node_modules").mkdir(parents=True)
        for name in ("swift", "node", "nc") + (() if lean else ("PincerChecks",)):
            command = root / ("bin" if name == "PincerChecks" else "fake") / name
            command.write_text(FAKE); command.chmod(0o755)
        env = dict(os.environ, PATH=str(root / "fake") + os.pathsep + os.environ["PATH"],
                   CHECKS_FIXTURE_ROOT=str(root), CHECKS_FIXTURE_REAL_NODE=shutil.which("node") or "",
                   CHECKS_LOG_DIR=str(root / "logs"), CHECKS_PORT_BASE="29901", CHECKS_PROGRESS_INTERVAL="0.1",
                   CHECKS_FIXTURE_NOGATE="1")
        if shard is None: env.pop("CHECKS_SHARD", None)
        else: env["CHECKS_SHARD"] = shard
        done = subprocess.run(["/bin/bash", str(root / "scripts" / "run-checks.sh")], env=env, stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
        text = done.stdout.decode("utf-8", errors="replace")
        lines = text.splitlines()
        lanes = []
        if "Lane               Result  Time   Last line" in lines:
            for line in lines[lines.index("Lane               Result  Time   Last line") + 1:]:
                if line.startswith("Logs:"): break
                if line.split(): lanes.append(line.split()[0])
        calls = root / "swift-test-calls"
        return done.returncode, text, lanes, len(list((root / "mocks").glob("*.pid"))), len(calls.read_text().split()) if calls.exists() else 0


def shard_controls():
    results = {}
    code, text, lanes, mocks, calls = execute_shard("unit", lean=True)
    results["unitShardRunsExactlyUnitLanes"] = code == 0 and lanes == UNIT_LANES
    results["unitShardStartsNoMock"] = mocks == 0 and calls == 2
    code, text, lanes, mocks, calls = execute_shard("checks")
    results["checksShardRunsExactlyCheckLanes"] = code == 0 and lanes == CHECKS_LANES
    results["checksShardNeverRunsSwiftTest"] = calls == 0 and mocks == 6
    code, text, lanes, mocks, calls = execute_shard("bogus")
    results["bogusShardRejected"] = code != 0 and "CHECKS_SHARD must be all, unit or checks, not bogus" in text and not lanes and mocks == 0 and calls == 0
    code, text, lanes, mocks, calls = execute_shard(None)
    results["defaultShardRunsAllLanes"] = code == 0 and lanes == ALL_LANES and calls == 2 and mocks == 6
    code, text, lanes, mocks, calls = execute_shard("all")
    results["explicitAllMatchesDefault"] = code == 0 and lanes == ALL_LANES
    print(json.dumps(results, sort_keys=True))
    failed = [key for key, ok in results.items() if not ok]
    if failed:
        print("shard fixture failed: " + ", ".join(failed), file=sys.stderr)
        return 1
    return 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--completed-control", action="store_true")
    parser.add_argument("--failed-lane-control", action="store_true")
    parser.add_argument("--require-safe-identity", action="store_true")
    parser.add_argument("--interrupt-control", action="store_true")
    parser.add_argument("--stale-completion-control", action="store_true")
    parser.add_argument("--shard-controls", action="store_true")
    args = parser.parse_args()
    if args.shard_controls: return shard_controls()
    status = execute(not (args.completed_control or args.failed_lane_control), args.failed_lane_control, args.require_safe_identity, args.interrupt_control, args.stale_completion_control)
    return status or (shard_controls() if len(sys.argv) == 1 else 0)


if __name__ == "__main__":
    sys.exit(main())
