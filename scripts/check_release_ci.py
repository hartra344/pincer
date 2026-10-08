#!/usr/bin/env python3
"""Require a completed, successful Tests push run for the exact release commit."""
import json
import os
import re
import subprocess
import sys


def validated_run(runs, sha):
    candidates = [run for run in runs if run.get("head_sha") == sha
                  and run.get("event") == "push" and run.get("head_branch") == "main"]
    if not candidates:
        raise ValueError("No Tests push run exists on main for this exact commit.")
    latest = max(candidates, key=lambda run: run["id"])
    if latest.get("status") != "completed" or latest.get("conclusion") != "success":
        raise ValueError("The latest Tests run for this commit is not completed successfully: "
                         + latest.get("html_url", "see the Tests workflow"))
    return latest


if __name__ == "__main__":
    if len(sys.argv) != 2 or not re.fullmatch(r"[0-9a-f]{40}", sys.argv[1]):
        sys.exit("usage: check_release_ci.py <full-commit-sha>")
    sha = sys.argv[1]
    repo = os.environ["GITHUB_REPOSITORY"]
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
        sys.exit("Invalid repository name")
    endpoint = f"repos/{repo}/actions/workflows/tests.yml/runs?head_sha={sha}&event=push&per_page=100"
    data = json.loads(subprocess.check_output(["gh", "api", endpoint]))
    try:
        run = validated_run(data["workflow_runs"], sha)
    except ValueError as error:
        sys.exit(str(error) + " Wait for green checks, then rerun TestFlight.")
    print("Validated release commit against " + run["html_url"])
