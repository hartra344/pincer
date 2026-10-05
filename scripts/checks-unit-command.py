#!/usr/bin/env python3
"""Run the owned unit command with a bounded diagnostic ceiling, preserving normal status."""
import json
import math
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


def ceiling():
    # Shorter intervals support the owned harness; callers cannot raise the 300-second ceiling.
    try:
        value = float(os.environ.get("CHECKS_UNIT_TIMEOUT_SECONDS", "300"))
        return max(0.1, min(300, value)) if math.isfinite(value) else 300
    except ValueError:
        return 300


def process_snapshot(timeout=5):
    result = subprocess.run(["/bin/ps", "-axo", "pid=,ppid=,lstart=,comm="], capture_output=True,
                            text=True, timeout=timeout, check=True)
    records = {}
    for line in result.stdout.splitlines():
        fields = line.split(None, 7)
        if len(fields) == 8 and fields[0].isdigit() and fields[1].isdigit():
            records[int(fields[0])] = (int(fields[1]), " ".join(fields[2:7]), fields[7])
    return records


def owned_members(leader, records):
    # SwiftPM's helper may have a distinct process group; use current parentage for sampling.
    owned = {leader}
    changed = True
    while changed:
        changed = False
        for pid, (parent, _, _) in records.items():
            if parent in owned and pid not in owned:
                owned.add(pid); changed = True
    def priority(pid):
        command = records.get(pid, (0, "", ""))[2]
        helper = any(name in command for name in ("swiftpm-testing-helper", ".xctest", "PincerKitTests", "PincerUITests"))
        return (not helper, pid == leader, pid)
    return sorted(owned, key=priority)[:8]


def sample_owned(group, directory, evidence=None):
    samples = []
    details = evidence if evidence is not None else {}
    details["sampleCandidates"] = []
    details["sampleErrors"] = []
    if sys.platform != "darwin":
        return samples
    deadline = time.monotonic() + 30
    try:
        records = process_snapshot(timeout=min(5, deadline - time.monotonic()))
        members = owned_members(group, records)
    except (OSError, subprocess.SubprocessError) as error:
        details["sampleErrors"].append({"stage": "snapshot", "error": type(error).__name__})
        return samples
    for pid in members:
        identity = records.get(pid)
        details["sampleCandidates"].append({"pid": pid, "parent": identity[0] if identity else None, "started": identity[1] if identity else None, "command": identity[2] if identity else None})
        try:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            # Recheck start identity AND current ancestry immediately before reading stacks.
            current = process_snapshot(timeout=min(5, remaining))
            if current.get(pid) != records.get(pid) or pid not in owned_members(group, current):
                details["sampleErrors"].append({"pid": pid, "stage": "identity", "error": "ownershipChanged"})
                continue
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            name = "unit-stack-" + str(pid) + ".txt"
            with (directory / (name + ".sampler.log")).open("wb") as output:
                result = subprocess.run(["/usr/bin/sample", str(pid), "1", "1", "-file", str(directory / name)],
                                        stdout=output, stderr=subprocess.STDOUT, timeout=remaining)
            if result.returncode == 0 and (directory / name).is_file():
                samples.append(name)
            else:
                details["sampleErrors"].append({"pid": pid, "stage": "sample", "returncode": result.returncode})
        except (OSError, subprocess.SubprocessError) as error:
            details["sampleErrors"].append({"pid": pid, "stage": "sample", "error": type(error).__name__})
            continue
    return samples


def main():
    if len(sys.argv) < 2:
        return 2
    child = subprocess.Popen(sys.argv[1:], start_new_session=True)
    forwarding = False
    watchdog_active = False
    signal_errors = []

    def forward(signum, _frame):
        nonlocal forwarding
        if forwarding:
            return
        forwarding = True
        try:
            # During capture nothing reaps the leader. Otherwise poll prevents stale signals.
            if watchdog_active or (child.returncode is None and child.poll() is None):
                try:
                    os.killpg(child.pid, signum)
                except OSError as error:
                    signal_errors.append({"signal": signal.Signals(signum).name, "errno": error.errno})
        finally:
            forwarding = False

    previous_term = signal.signal(signal.SIGTERM, forward)
    previous_int = signal.signal(signal.SIGINT, forward)
    try:
        timeout = ceiling()
        try:
            code = child.wait(timeout=timeout)
            return code if code >= 0 else 128 - code
        except subprocess.TimeoutExpired:
            watchdog_active = True
            directory = Path(os.environ.get("CHECKS_LOG_DIR", "."))
            evidence = {"timedOut": True, "ownedPid": child.pid, "ceilingSeconds": timeout, "samples": [], "nativeDescendantCleanupVerified": False, "signalErrors": signal_errors, "captureWindowSeconds": 30}
            try:
                directory.mkdir(parents=True, exist_ok=True)
                (directory / "unit-watchdog.json").write_text(json.dumps(evidence) + "\n")
                evidence["samples"] = sample_owned(child.pid, directory, evidence)
                (directory / "unit-watchdog.json").write_text(json.dumps(evidence) + "\n")
            except OSError:
                pass
            finally:
                # Both signals precede wait/reap; the unreaped owned leader pins its group.
                for kind in (signal.SIGTERM, signal.SIGKILL):
                    try:
                        os.killpg(child.pid, kind)
                    except OSError as error:
                        signal_errors.append({"signal": kind.name, "errno": error.errno})
                    if kind == signal.SIGTERM:
                        time.sleep(2)
                watchdog_active = False
                try:
                    evidence["ownedReturnCode"] = child.wait(timeout=5)
                    evidence["ownedReaped"] = True
                except (OSError, subprocess.SubprocessError) as error:
                    evidence["ownedReaped"] = False
                    evidence["reapError"] = type(error).__name__
                try:
                    (directory / "unit-watchdog.json").write_text(json.dumps(evidence) + "\n")
                except OSError:
                    pass
            print("Unit diagnostic ceiling exceeded; owned stack samples=" + str(len(evidence["samples"])), flush=True)
            return 1
    finally:
        signal.signal(signal.SIGTERM, previous_term)
        signal.signal(signal.SIGINT, previous_int)


if __name__ == "__main__":
    sys.exit(main())
