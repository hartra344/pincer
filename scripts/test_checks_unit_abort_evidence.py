#!/usr/bin/env python3
"""Actual owned abort evidence control; no native crash report is invented or read."""
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("unit_command_abort", Path(__file__).with_name("checks-unit-command.py"))
wrapper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wrapper)
real_spawn = subprocess.Popen
children = []

def spawn(*args, **kwargs):
    child = real_spawn(*args, **kwargs)
    if args and args[0] == command:
        children.append(child)
    return child

with tempfile.TemporaryDirectory(prefix="pincer-owned-unit-abort-") as temporary:
    root = Path(temporary)
    entered = root / "entered"
    command = [sys.executable, "-c", "import os,resource,sys; resource.setrlimit(resource.RLIMIT_CORE,(0,0)); open(sys.argv[1],'w').write(str(os.getpid())); os.abort()", str(entered)]
    try:
        with patch.object(wrapper.subprocess, "Popen", side_effect=spawn), patch.object(sys, "argv", ["checks-unit-command.py", *command]), patch.dict(os.environ, {"CHECKS_LOG_DIR": temporary, "CHECKS_UNIT_TIMEOUT_SECONDS": "10"}):
            status = wrapper.main()
        assert len(children) == 1 and entered.is_file(), "actual owned child admission prerequisite"
        child = children[0]
        assert int(entered.read_text()) == child.pid, "actual entry belongs to owned child"
        assert child.returncode == -signal.SIGABRT and status == 128 + signal.SIGABRT, "actual abort exit must be preserved"
        evidence_path = root / "unit-command-exit.json"
        assert evidence_path.is_file(), "non-timeout actual abort must retain owned exit evidence"
        evidence = json.loads(evidence_path.read_text())
        assert evidence["ownedPid"] == child.pid and evidence["ownedReturnCode"] == -signal.SIGABRT
        assert evidence["timedOut"] is False and evidence["ownedStarted"], "identity must be captured before owned exit"
        print("actual owned abort exit and non-timeout identity evidence PASS")
    finally:
        for child in children:
            if child.poll() is None:
                child.terminate()
                try: child.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    if child.poll() is None: child.kill()
                    child.wait(timeout=3)
            else:
                child.wait()
