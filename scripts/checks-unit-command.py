#!/usr/bin/env python3
"""Run the owned unit command with a bounded diagnostic ceiling, preserving normal status."""
import ctypes
from datetime import datetime, timezone
import json
import math
import os
from pathlib import Path
import signal
import stat
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


def mac_process_identity(pid):
    """SDK libproc birth/path/parent identity, read twice to reject PID replacement."""
    if sys.platform != "darwin":
        return None
    class Usage(ctypes.Structure):
        _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in
            ("user", "system", "idle", "interrupts", "pageins", "wired", "resident", "footprint", "birth", "exit")]
    class BSD(ctypes.Structure):
        _fields_ = [(name, ctypes.c_uint32) for name in
            ("flags", "status", "xstatus", "pid", "parent", "uid", "gid", "ruid", "rgid", "svuid", "svgid", "reserved")] + [
            ("comm", ctypes.c_char * 16), ("name", ctypes.c_char * 32)] + [
            (name, ctypes.c_uint32) for name in ("files", "group", "job", "dev", "tgroup", "nice")] + [
            ("seconds", ctypes.c_uint64), ("micros", ctypes.c_uint64)]
    try:
        lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        first, second, bsd = Usage(), Usage(), BSD()
        path = ctypes.create_string_buffer(4096)
        if lib.proc_pid_rusage(pid, 0, ctypes.byref(first)) != 0:
            return None
        if lib.proc_pidinfo(pid, 3, 0, ctypes.byref(bsd), ctypes.sizeof(bsd)) != ctypes.sizeof(bsd):
            return None
        if lib.proc_pidpath(pid, path, len(path)) <= 0 or lib.proc_pid_rusage(pid, 0, ctypes.byref(second)) != 0:
            return None
        if not first.birth or first.birth != second.birth or bsd.pid != pid:
            return None
        return {"pid": pid, "parent": bsd.parent, "path": os.fsdecode(path.value), "procStartAbsTime": first.birth}
    except (OSError, ValueError, AttributeError):
        return None


def parse_native_report(data):
    try:
        text = data.decode("utf-8")
        try:
            result = json.loads(text)
        except json.JSONDecodeError:
            _, body = text.split("\n", 1)
            result = json.loads(body)
        return result if isinstance(result, dict) else None
    except (UnicodeError, ValueError):
        return None


def match_report(report, identities):
    if not isinstance(report, dict):
        return False
    pid, birth, path = report.get("pid"), report.get("procStartAbsTime"), report.get("procPath")
    if type(pid) is not int or type(birth) is not int or birth <= 0 or not isinstance(path, str) or not path:
        return False
    identities = identities.values() if isinstance(identities, dict) else identities
    return any(identity.get("owned") is True and identity.get("pid") == pid and
               identity.get("procStartAbsTime") == birth and identity.get("path") == path
               for identity in identities)


def collect_native_reports(directory, identities, deadline, source=None):
    result = {"outcome": "noMatch" if identities else "identityUnavailable", "reports": [], "errors": []}
    if sys.platform != "darwin" or not identities:
        return result
    identities = list(identities.values()) if isinstance(identities, dict) else list(identities)
    source = Path(source) if source is not None else Path.home() / "Library/Logs/DiagnosticReports"
    allowed_names = {Path(identity["path"]).name for identity in identities}
    considered = 0
    remaining_bytes = 16 * 1024 * 1024
    seen = set()
    while time.monotonic() < deadline and considered < 128 and remaining_bytes > 0:
        try:
            with os.scandir(source) as entries:
                for entry in entries:
                    if time.monotonic() >= deadline or considered >= 128 or remaining_bytes <= 0:
                        break
                    if entry.name in seen or not entry.name.endswith(".ips") or (allowed_names is not None and not any(entry.name.startswith(name + "-") for name in allowed_names)):
                        continue
                    seen.add(entry.name); considered += 1
                    try:
                        fd = os.open(entry.path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
                        with os.fdopen(fd, "rb") as stream:
                            info = os.fstat(stream.fileno())
                            if not stat.S_ISREG(info.st_mode) or info.st_size > min(2 * 1024 * 1024, remaining_bytes):
                                continue
                            data = stream.read(min(2 * 1024 * 1024, remaining_bytes) + 1)
                        remaining_bytes -= len(data)
                        if len(data) > 2 * 1024 * 1024 or not match_report(parse_native_report(data), identities):
                            continue
                        name = "unit-owned-report-" + str(len(result["reports"])) + ".ips"
                        (Path(directory) / name).write_bytes(data)
                        result["reports"].append(name); result["outcome"] = "matchedOwnedReport"
                        return result
                    except OSError as error:
                        result["errors"].append({"stage": "reportRead", "errno": error.errno})
        except OSError as error:
            result["errors"].append({"stage": "reportDirectory", "errno": error.errno}); break
        if result["reports"]:
            break
        time.sleep(min(0.25, max(0, deadline - time.monotonic())))
    return result


def capture_owned_identities(child, leader, table, deadline):
    if sys.platform != "darwin" or leader is None or time.monotonic() >= deadline:
        return
    try:
        records = process_snapshot(timeout=min(0.5, deadline - time.monotonic()))
        def same_birth(value):
            return value is not None and value["pid"] == child.pid and value["procStartAbsTime"] == leader["procStartAbsTime"]
        if not same_birth(mac_process_identity(child.pid)):
            return
        for pid in owned_members(child.pid, records):
            if time.monotonic() >= deadline:
                break
            identity = mac_process_identity(pid)
            if identity is None or identity["parent"] != records.get(pid, (None,))[0]:
                continue
            # Verify the live ancestry, including each parent's birth, before recording ownership.
            current = identity
            chain = []
            while current["pid"] != child.pid and len(chain) < 8 and time.monotonic() < deadline:
                chain.append(current)
                current = mac_process_identity(current["parent"])
                if current is None:
                    break
            if not same_birth(current) or not same_birth(mac_process_identity(child.pid)) or any(mac_process_identity(item["pid"]) != item for item in chain):
                continue
            key = (identity["pid"], identity["procStartAbsTime"])
            if key not in table and len(table) >= 8:
                helper = any(name in identity["path"] for name in ("swiftpm-testing-helper", ".xctest", "PincerKitTests", "PincerUITests"))
                if helper:
                    replace = next((old for old, value in table.items() if value["pid"] != child.pid and not any(
                        name in value["path"] for name in ("swiftpm-testing-helper", ".xctest", "PincerKitTests", "PincerUITests"))), None)
                    if replace is not None:
                        del table[replace]
            # A legitimate exec keeps PID/birth but changes the executable path. Retain
            # the latest fully verified identity so a matching owned crash remains eligible.
            if key in table or len(table) < 8:
                table[key] = dict(identity, owned=True)
    except (OSError, subprocess.SubprocessError):
        pass


def retain_exit_evidence(child, code, started, identities):
    directory = Path(os.environ.get("CHECKS_LOG_DIR", "."))
    evidence = {"ownedPid": child.pid, "ownedReturnCode": code, "timedOut": False,
                "ownedStarted": started, "ownedFinished": datetime.now(timezone.utc).isoformat(),
                "observedNativeIdentities": list(identities.values()), "reportCapture": {"outcome": "pending", "reports": []}}
    try:
        directory.mkdir(parents=True, exist_ok=True)
        target = directory / "unit-command-exit.json"
        target.write_text(json.dumps(evidence) + "\n")
        evidence["reportCapture"] = collect_native_reports(directory, identities, time.monotonic() + 10)
        target.write_text(json.dumps(evidence) + "\n")
        print("Owned unit command failed; exit metadata retained, reports=" + str(len(evidence["reportCapture"]["reports"])), flush=True)
    except (OSError, ValueError) as error:
        print("Owned unit exit diagnostic unavailable: " + type(error).__name__, flush=True)


def main():
    if len(sys.argv) < 2:
        return 2
    started = datetime.now(timezone.utc).isoformat()
    launched_at = time.monotonic()
    command_environment = os.environ.copy()
    if sys.platform == "darwin":
        # Swift 6.3 docs/Backtracing.rst: noninteractive crash diagnostics. timeout=0s
        # disables interaction only; the owned-command watchdog still bounds processing.
        command_environment.setdefault("SWIFT_BACKTRACE",
            "enable=yes,interactive=no,color=no,timeout=0s,threads=crashed,registers=none,"
            "images=all,limit=32,symbolicate=fast,sanitize=yes,output-to=stderr")
    child = subprocess.Popen(sys.argv[1:], start_new_session=True, env=command_environment)
    leader_identity = mac_process_identity(child.pid)
    identities = {}
    if leader_identity is not None:
        identities[(child.pid, leader_identity["procStartAbsTime"])] = dict(leader_identity, owned=True)
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
            deadline = launched_at + timeout
            while True:
                try:
                    code = child.wait(timeout=min(5, max(0, deadline - time.monotonic())))
                    break
                except subprocess.TimeoutExpired:
                    if time.monotonic() >= deadline:
                        raise
                    capture_owned_identities(child, leader_identity, identities, deadline)
            if code != 0:
                retain_exit_evidence(child, code, started, identities)
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
