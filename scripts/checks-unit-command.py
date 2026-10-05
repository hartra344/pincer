#!/usr/bin/env python3
"""Own the unit command's process group and preserve its output and exit status.

Neutral pass-through: no diagnostic timer or sampling policy yet.
"""
import os
import signal
import subprocess
import sys


def main():
    if len(sys.argv) < 2:
        return 2
    child = subprocess.Popen(sys.argv[1:], start_new_session=True)

    def forward(signum, _frame):
        try:
            os.killpg(child.pid, signum)
        except ProcessLookupError:
            pass

    signal.signal(signal.SIGTERM, forward)
    signal.signal(signal.SIGINT, forward)
    try:
        code = child.wait()
        return code if code >= 0 else 128 - code
    finally:
        # The group belongs to this invocation, including descendants of the command.
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


if __name__ == "__main__":
    sys.exit(main())
