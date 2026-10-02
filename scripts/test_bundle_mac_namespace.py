#!/usr/bin/env python3
"""Exercise bundle-mac.sh with isolated fake build tools and inspect its Info.plist."""

from __future__ import annotations

import os
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
import unittest


REPO = pathlib.Path(__file__).resolve().parents[1]


class BundleMacNamespaceTests(unittest.TestCase):
    def test_namespace_is_applied_to_bundle_identity_and_info_plist(self) -> None:
        with tempfile.TemporaryDirectory(prefix="pincer-bundle-namespace-") as temporary:
            root = pathlib.Path(temporary)
            repo = root / "repo"
            tools = root / "fake-tools"
            swift_bin = root / "swift-bin"
            (repo / "scripts").mkdir(parents=True)
            (repo / "Apps/Shared").mkdir(parents=True)
            tools.mkdir()
            swift_bin.mkdir()
            shutil.copy2(REPO / "scripts/bundle-mac.sh", repo / "scripts/bundle-mac.sh")
            (repo / "Apps/Shared/AppIcon.icon").write_text("fake icon\n", encoding="utf-8")
            (swift_bin / "PincerMacDev").write_text("fake executable\n", encoding="utf-8")

            self.write_tool(tools / "swift", """#!/bin/sh
if [ "$1" = build ] && [ "$4" = --show-bin-path ]; then
    printf '%s\\n' "$PINCER_TEST_SWIFT_BIN"
fi
""")
            self.write_tool(tools / "xcrun", """#!/usr/bin/env python3
import pathlib
import sys

args = sys.argv[1:]
if args[:2] == ["--sdk", "macosx"]:
    print("15.0")
elif args[:1] == ["actool"]:
    compile_path = pathlib.Path(args[args.index("--compile") + 1])
    partial_path = pathlib.Path(args[args.index("--output-partial-info-plist") + 1])
    compile_path.mkdir(parents=True, exist_ok=True)
    (compile_path / "Assets.car").touch()
    partial_path.parent.mkdir(parents=True, exist_ok=True)
    partial_path.touch()
else:
    raise SystemExit(f"unexpected xcrun arguments: {args}")
""")
            for name in ("vtool", "codesign"):
                self.write_tool(tools / name, "#!/bin/sh\nexit 0\n")

            base_env = os.environ.copy()
            base_env.pop("PINCER_DEV_NAMESPACE", None)
            base_env.update({
                "PATH": f"{tools}{os.pathsep}{base_env.get('PATH', '')}",
                "PINCER_TEST_SWIFT_BIN": str(swift_bin),
                "PINCER_SIGN_IDENTITY": "-",
            })

            def bundle(case: str, namespace: str | None) -> dict[str, object]:
                env = base_env.copy()
                env["PINCER_BUNDLE_ROOT"] = str(root / case)
                if namespace is None:
                    env.pop("PINCER_DEV_NAMESPACE", None)
                else:
                    env["PINCER_DEV_NAMESPACE"] = namespace
                subprocess.run(
                    [str(repo / "scripts/bundle-mac.sh"), "debug"],
                    cwd=repo,
                    env=env,
                    check=True,
                    text=True,
                    capture_output=True,
                )
                return self.read_info(root / case / "Pincer.app/Contents/Info.plist")

            production_info = bundle("ordinary-build", None)
            self.assertEqual(production_info["CFBundleIdentifier"], "chat.pincer.mac")
            self.assertNotIn("PincerDevSuffix", production_info)

            namespaced_info = bundle("namespaced-build", "Desk_Work!")
            self.assertEqual(namespaced_info["CFBundleIdentifier"], "chat.pincer.mac.dev-desk-work")
            self.assertEqual(namespaced_info["PincerDevSuffix"], ".dev-desk-work")

            for case, namespace in (("empty-build", ""), ("punctuation-build", "!!!")):
                invalid_info = bundle(case, namespace)
                self.assertEqual(invalid_info["CFBundleIdentifier"], "chat.pincer.mac")
                self.assertNotIn("PincerDevSuffix", invalid_info)

            long_name = "A" * 30
            long_info = bundle("long-build", long_name)
            self.assertEqual(long_info["CFBundleIdentifier"], f"chat.pincer.mac.dev-{'a' * 24}")
            self.assertEqual(long_info["PincerDevSuffix"], f".dev-{'a' * 24}")

            leading_invalid_info = bundle("leading-invalid-build", "!" + "A" * 24)
            self.assertEqual(leading_invalid_info["CFBundleIdentifier"], f"chat.pincer.mac.dev-{'a' * 23}")
            self.assertEqual(leading_invalid_info["PincerDevSuffix"], f".dev-{'a' * 23}")

            multiline_info = bundle("multiline-build", "Desk\nWork")
            self.assertEqual(multiline_info["CFBundleIdentifier"], "chat.pincer.mac.dev-desk-work")
            self.assertEqual(multiline_info["PincerDevSuffix"], ".dev-desk-work")

            unicode_info = bundle("unicode-build", "K_İ")
            self.assertEqual(unicode_info["CFBundleIdentifier"], "chat.pincer.mac.dev-k-i")
            self.assertEqual(unicode_info["PincerDevSuffix"], ".dev-k-i")

    @staticmethod
    def read_info(path: pathlib.Path) -> dict[str, object]:
        with path.open("rb") as plist_file:
            return plistlib.load(plist_file)

    @staticmethod
    def write_tool(path: pathlib.Path, contents: str) -> None:
        path.write_text(contents, encoding="utf-8")
        path.chmod(0o755)


if __name__ == "__main__":
    unittest.main()
