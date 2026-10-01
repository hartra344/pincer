#!/usr/bin/env python3
"""Runs the docs capture packager with fake Apple build tools and checks staging isolation."""

from __future__ import annotations

import os
import pathlib
import re
import shutil
import subprocess
import tempfile
import unittest


REPO = pathlib.Path(__file__).resolve().parents[1]


class DocsCaptureIsolationTests(unittest.TestCase):
    def test_repeated_captures_do_not_share_asset_staging(self) -> None:
        with tempfile.TemporaryDirectory(prefix="pincer-docs-capture-test-") as temporary:
            root = pathlib.Path(temporary)
            repo = root / "repo"
            tools = root / "fake-tools"
            swift_bin = root / "swift-bin"
            (repo / "scripts").mkdir(parents=True)
            (repo / "Apps/Shared").mkdir(parents=True)
            tools.mkdir()
            swift_bin.mkdir()
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
            self.write_tool(tools / "xcrun", """
                #!/bin/sh
                if [ "$1" = --sdk ]; then
                    printf '15.0\\n'
                    exit 0
                fi
                compile=''
                partial=''
                while [ "$#" -gt 0 ]; do
                    case "$1" in
                        --compile) compile=$2; shift 2 ;;
                        --output-partial-info-plist) partial=$2; shift 2 ;;
                        *) shift ;;
                    esac
                done
                mkdir -p "$compile" "$(dirname "$partial")"
                : > "$compile/Assets.car"
                : > "$partial"
                printf '%s\\t%s\\t%s\\n' "$PINCER_TEST_RUN_ID" "$compile" "$partial" >> "$PINCER_TEST_LOG"
            """)
            for name in ("vtool", "codesign", "defaults"):
                self.write_tool(tools / name, "#!/bin/sh\nexit 0\n")

            env = os.environ.copy()
            env.update({
                "PATH": f"{tools}{os.pathsep}{env.get('PATH', '')}",
                "PINCER_TEST_SWIFT_BIN": str(swift_bin),
                "PINCER_TEST_LOG": str(log),
            })
            output_paths = []
            for run_id in ("first", "second"):
                run_env = env | {"PINCER_TEST_RUN_ID": run_id}
                result = subprocess.run(
                    [str(repo / "scripts/prepare-docs-capture.sh"), "debug"],
                    cwd=repo,
                    env=run_env,
                    text=True,
                    capture_output=True,
                    check=True,
                )
                match = re.search(r"Capture app prepared: (.+)", result.stdout)
                self.assertIsNotNone(match, result.stdout)
                output_paths.append(match.group(1))

            rows = [line.split("\t") for line in log.read_text(encoding="utf-8").splitlines()]
            self.assertEqual([row[0] for row in rows], ["first", "second"])
            self.assertNotEqual(rows[0][1], rows[1][1], "actool resource output directories must be per invocation")
            self.assertNotEqual(rows[0][2], rows[1][2], "actool partial plists must be per invocation")
            self.assertNotEqual(output_paths[0], output_paths[1], "each capture gets its own generated app path")

    @staticmethod
    def write_tool(path: pathlib.Path, contents: str) -> None:
        path.write_text(contents, encoding="utf-8")
        path.chmod(0o755)


if __name__ == "__main__":
    unittest.main()
