#!/usr/bin/env python3
"""Owned native identity proof plus explicitly synthetic parser/scanner-only controls."""
import importlib.util
import json
import os
import select
from pathlib import Path
import subprocess
import sys
import tempfile
import time
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("unit_native_evidence", Path(__file__).with_name("checks-unit-command.py"))
wrapper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wrapper)

# Actual installed macOS process APIs, applied only to this fixture's owned live child.
child = subprocess.Popen([sys.executable, "-c", "import os,sys; print(os.getpid(),flush=True); sys.stdin.buffer.read(1); os.execv('/bin/cat',['cat'])"], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
try:
    assert select.select([child.stdout], [], [], 3)[0], "actual Python exec readiness must arrive"
    marker = os.read(child.stdout.fileno(), 64)
    assert marker == (str(child.pid) + "\n").encode(), "actual ready marker must identify owned Python child"
    first = wrapper.mac_process_identity(child.pid)
    second = wrapper.mac_process_identity(child.pid)
    assert first and second and first == second, "owned live native identity must be stable"
    assert first["pid"] == child.pid and first["parent"] == os.getpid()
    assert first["procStartAbsTime"] > 0 and first["path"].startswith("/")
    child.stdin.write(b"x"); child.stdin.flush()
    deadline = time.monotonic() + 3
    executed = None
    while time.monotonic() < deadline:
        observed = wrapper.mac_process_identity(child.pid)
        if observed and observed["path"] == "/bin/cat":
            executed = observed
            break
        time.sleep(0.01)
    assert executed and executed["pid"] == first["pid"] and executed["parent"] == first["parent"]
    assert executed["procStartAbsTime"] == first["procStartAbsTime"], "actual same-PID exec retains birth"
    identity_key = (first["pid"], first["procStartAbsTime"])
    table = {identity_key: dict(first, owned=True)}
    wrapper.capture_owned_identities(child, first, table, time.monotonic() + 2)
    assert table[identity_key]["path"] == executed["path"], "verified same-birth exec path must replace retained identity"
    child.stdin.close()
    assert child.wait(timeout=3) == 0
finally:
    if child.poll() is None:
        child.terminate()
        try: child.wait(timeout=3)
        except subprocess.TimeoutExpired:
            if child.poll() is None: child.kill()
            child.wait(timeout=3)
    else: child.wait()

# PARSER-ONLY synthetic matching data. This is not an operating-system crash report.
identity = dict(first, owned=True)
identities = {first["pid"]: identity}
report = {"pid": first["pid"], "procStartAbsTime": first["procStartAbsTime"], "procPath": first["path"]}
encoded = json.dumps({"fixture": "synthetic parser header"}).encode() + b"\n" + json.dumps(report).encode()
assert wrapper.parse_native_report(encoded) == report
assert wrapper.match_report(report, identities)
for field, value in [("pid", first["pid"] + 1), ("procStartAbsTime", first["procStartAbsTime"] + 1), ("procPath", first["path"] + ".other")]:
    changed = dict(report, **{field: value})
    assert not wrapper.match_report(changed, identities), "PID reuse/path mismatch must reject"
for value in [None, "invalid", {}, [], True]:
    changed = dict(report, procStartAbsTime=value)
    assert not wrapper.match_report(changed, identities)
missing = dict(report); del missing["procStartAbsTime"]
assert not wrapper.match_report(missing, identities)
assert not wrapper.match_report(report, {first["pid"]: dict(first, owned=False)})
assert not wrapper.match_report(report, {})
assert wrapper.parse_native_report(b"not JSON") is None

# SCANNER-ONLY owned scratch reports; never inspect another process's DiagnosticReports.
with tempfile.TemporaryDirectory(prefix="pincer-native-report-parser-") as temporary:
    root = Path(temporary)
    reports = root / "reports"; reports.mkdir()
    captures = root / "captures"; captures.mkdir()
    prefix = Path(first["path"]).name + "-"
    outside = root / "outside.ips"; outside.write_bytes(encoded)
    (reports / (prefix + "linked.ips")).symlink_to(outside)
    (reports / (prefix + "oversized.ips")).write_bytes(b" " * (2 * 1024 * 1024 + 1))
    rejected = wrapper.collect_native_reports(captures, identities, time.monotonic() + 2, source=reports)
    assert not rejected["reports"], "symlink/oversize scratch candidates must never be captured"
    (reports / (prefix + "matching.ips")).write_bytes(encoded)
    captured = wrapper.collect_native_reports(captures, identities, time.monotonic() + 2, source=reports)
    assert len(captured["reports"]) == 1, "paired regular matching scratch report qualifies"
    expired = wrapper.collect_native_reports(captures, identities, time.monotonic() - 1, source=reports)
    assert not expired["reports"], "expired scanner budget must not read reports"
print("actual owned native identity and synthetic parser/scanner controls PASS")

# Actual healthy owned command must bypass failure-only native report scanning.
with tempfile.TemporaryDirectory(prefix="pincer-healthy-unit-evidence-") as temporary:
    marker = Path(temporary) / "healthy-pid"
    command = [sys.executable, "-c", "import os,sys; open(sys.argv[1],'w').write(str(os.getpid()))", str(marker)]
    real_spawn = subprocess.Popen
    primary = []
    def spawn(*args, **kwargs):
        process = real_spawn(*args, **kwargs)
        if args and args[0] == command:
            primary.append(process)
        return process
    try:
        with patch.object(wrapper.subprocess, "Popen", side_effect=spawn), patch.object(sys, "argv", ["checks-unit-command.py", *command]), patch.dict(os.environ, {"CHECKS_LOG_DIR": temporary, "CHECKS_UNIT_TIMEOUT_SECONDS": "10"}), patch.object(wrapper, "collect_native_reports", side_effect=AssertionError("healthy command must not scan reports")):
            status = wrapper.main()
        assert len(primary) == 1 and marker.is_file()
        assert int(marker.read_text()) == primary[0].pid and primary[0].returncode == 0 and status == 0
        assert not (Path(temporary) / "unit-command-exit.json").exists(), "healthy command must not emit failure metadata"
    finally:
        for process in primary:
            if process.poll() is None:
                process.terminate()
                try: process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    if process.poll() is None: process.kill()
                    process.wait(timeout=3)
            else: process.wait()
print("actual healthy owned command bypasses native report scanning PASS")
