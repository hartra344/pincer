#!/usr/bin/env python3
"""Runs the docs capture packager with fake Apple build tools and checks staging isolation."""

from __future__ import annotations

import os
import pathlib
import re
import shutil
import subprocess
import tempfile
import threading
import time
import unittest
from concurrent.futures import ThreadPoolExecutor


REPO = pathlib.Path(__file__).resolve().parents[1]


class DocsCaptureIsolationTests(unittest.TestCase):
    def test_concurrent_captures_and_developer_bundle_have_isolated_staging(self) -> None:
        with tempfile.TemporaryDirectory(prefix="pincer-docs-capture-test-") as temporary:
            root = pathlib.Path(temporary)
            repo = root / "repo"
            tools = root / "fake-tools"
            swift_bin = root / "swift-bin"
            barrier = root / "actool-barrier"
            (repo / "scripts").mkdir(parents=True)
            (repo / "Apps/Shared").mkdir(parents=True)
            tools.mkdir()
            swift_bin.mkdir()
            barrier.mkdir()
            shutil.copy2(REPO / "scripts/bundle-mac.sh", repo / "scripts/bundle-mac.sh")
            shutil.copy2(REPO / "scripts/prepare-docs-capture.sh", repo / "scripts/prepare-docs-capture.sh")
            (repo / "Apps/Shared/AppIcon.icon").write_text("fake icon source\n", encoding="utf-8")
            (swift_bin / "PincerMacDev").write_text("fake binary\n", encoding="utf-8")

            log = root / "actool-paths.tsv"
            self.write_tool(tools / "swift", """
                #!/bin/sh
                if [ "$1" = build ] && [ "$4" = --show-bin-path ]; then
                    printf '%s\\n' "$PINCER_TEST_SWIFT_BIN"
                fi
                exit 0
            """)
            self.write_tool(tools / "xcrun", f"""#!/usr/bin/env python3
import os
import pathlib
import sys
import time

if sys.argv[1:2] == ["--sdk"]:
    print("15.0")
    raise SystemExit(0)

args = sys.argv[1:]
compile_path = args[args.index("--compile") + 1]
partial_path = args[args.index("--output-partial-info-plist") + 1]
barrier = pathlib.Path({str(barrier)!r})
run_id = os.environ["PINCER_TEST_RUN_ID"]
(barrier / f"{{run_id}}.ready").touch()
deadline = time.monotonic() + 15
while len(list(barrier.glob("*.ready"))) < 3:
    if time.monotonic() >= deadline:
        raise SystemExit("timed out waiting for all three actool invocations")
    time.sleep(0.01)

pathlib.Path(compile_path).mkdir(parents=True, exist_ok=True)
pathlib.Path(compile_path, "Assets.car").touch()
pathlib.Path(partial_path).parent.mkdir(parents=True, exist_ok=True)
pathlib.Path(partial_path).touch()
with open(os.environ["PINCER_TEST_LOG"], "a", encoding="utf-8") as output:
    output.write(f"{{run_id}}\\t{{compile_path}}\\t{{partial_path}}\\n")
""")
            for name in ("vtool", "codesign", "defaults", "security"):
                self.write_tool(tools / name, "#!/bin/sh\nexit 0\n")

            env = os.environ.copy()
            env.update({
                "PATH": f"{tools}{os.pathsep}{env.get('PATH', '')}",
                "PINCER_TEST_SWIFT_BIN": str(swift_bin),
                "PINCER_TEST_LOG": str(log),
            })
            launch_barrier = threading.Barrier(3)

            def run(run_id: str, script: pathlib.Path) -> subprocess.CompletedProcess[str]:
                launch_barrier.wait(timeout=10)
                return subprocess.run(
                    [str(script), "debug"],
                    cwd=repo,
                    env=env | {"PINCER_TEST_RUN_ID": run_id},
                    text=True,
                    capture_output=True,
                    check=True,
                )

            capture_script = repo / "scripts/prepare-docs-capture.sh"
            bundle_script = repo / "scripts/bundle-mac.sh"
            with ThreadPoolExecutor(max_workers=3) as executor:
                futures = {
                    run_id: executor.submit(run, run_id, script)
                    for run_id, script in (
                        ("capture-one", capture_script),
                        ("capture-two", capture_script),
                        ("developer", bundle_script),
                    )
                }
                results = {run_id: future.result(timeout=30) for run_id, future in futures.items()}

            output_paths = []
            for run_id in ("capture-one", "capture-two"):
                result = results[run_id]
                match = re.search(r"Capture app prepared: (.+)", result.stdout)
                self.assertIsNotNone(match, result.stdout)
                output_path = pathlib.Path(match.group(1))
                self.assertTrue(output_path.is_absolute(), "the printed app path must be directly openable")
                self.assertTrue(output_path.is_dir(), "the printed app path must name the generated bundle")
                output_paths.append(str(output_path))

            rows = {
                row[0]: row[1:]
                for row in (line.split("\t") for line in log.read_text(encoding="utf-8").splitlines())
            }
            self.assertEqual(set(rows), {"capture-one", "capture-two", "developer"})
            self.assertNotEqual(rows["capture-one"][0], rows["capture-two"][0], "actool resource output directories must be per invocation")
            self.assertNotEqual(rows["capture-one"][1], rows["capture-two"][1], "actool partial plists must be per invocation")
            for capture_id in ("capture-one", "capture-two"):
                self.assertNotEqual(rows[capture_id][0], rows["developer"][0], "capture staging must not overlap the developer app")
                self.assertNotEqual(rows[capture_id][1], rows["developer"][1], "capture partial plist must not overlap developer staging")
            self.assertNotEqual(output_paths[0], output_paths[1], "each capture gets its own generated app path")
            self.assertEqual(rows["developer"][0], "build/Pincer.app/Contents/Resources", "ordinary developer bundle path stays stable")
            self.assertEqual(rows["developer"][1], "build/icon-partial.plist", "ordinary developer icon staging path stays stable")
            self.assertIn("Built build/Pincer.app", results["developer"].stdout)

    @staticmethod
    def write_tool(path: pathlib.Path, contents: str) -> None:
        path.write_text(contents, encoding="utf-8")
        path.chmod(0o755)


if __name__ == "__main__":
    unittest.main()
