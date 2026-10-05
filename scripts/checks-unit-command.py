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

    forwarding = False

    def forward(signum, _frame):
        nonlocal forwarding
        if forwarding:
            return
        forwarding = True
        # poll reaps an already-finished child; never signal a stored group ID after reap.
        try:
            if child.returncode is None and child.poll() is None:
                try:
                    os.killpg(child.pid, signum)
                except ProcessLookupError:
                    pass
        finally:
            forwarding = False

    previous_term = signal.signal(signal.SIGTERM, forward)
    previous_int = signal.signal(signal.SIGINT, forward)
    try:
        code = child.wait()
        return code if code >= 0 else 128 - code
    finally:
        signal.signal(signal.SIGTERM, previous_term)
        signal.signal(signal.SIGINT, previous_int)


if __name__ == "__main__":
    sys.exit(main())
