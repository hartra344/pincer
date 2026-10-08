#!/usr/bin/env python3
import sys
sys.dont_write_bytecode = True

import plistlib
import tempfile
import unittest
from pathlib import Path
from check_release_privacy import FULL, UI, validate_app, validate_manifest, validate_sources


def write_manifest(path, reasons):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(plistlib.dumps({
        "NSPrivacyTracking": False, "NSPrivacyTrackingDomains": [], "NSPrivacyCollectedDataTypes": [],
        "NSPrivacyAccessedAPITypes": [{"NSPrivacyAccessedAPIType": key, "NSPrivacyAccessedAPITypeReasons": sorted(value)} for key, value in reasons.items()],
    }))


class ReleasePrivacyTests(unittest.TestCase):
    def test_actual_sources_have_required_reasons(self):
        validate_sources()

    def test_missing_reason_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "PrivacyInfo.xcprivacy"
            write_manifest(path, UI)
            with self.assertRaises(ValueError):
                validate_manifest(path, FULL)

    def test_tracking_change_requires_review(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "PrivacyInfo.xcprivacy"
            write_manifest(path, FULL)
            data = plistlib.loads(path.read_bytes())
            data["NSPrivacyTracking"] = True
            path.write_bytes(plistlib.dumps(data))
            with self.assertRaises(ValueError):
                validate_manifest(path, FULL)

    def test_real_bundle_layouts_and_missing_extension_manifest(self):
        for platform in ("ios", "macos"):
            with self.subTest(platform=platform), tempfile.TemporaryDirectory() as folder:
                app = Path(folder) / "Pincer.app"
                resources = app / "Contents/Resources" if platform == "macos" else app
                plugins = app / "Contents/PlugIns" if platform == "macos" else app / "PlugIns"
                share = plugins / "PincerShare.appex"
                share_resources = share / "Contents/Resources" if platform == "macos" else share
                write_manifest(resources / "PrivacyInfo.xcprivacy", FULL)
                write_manifest(share_resources / "PrivacyInfo.xcprivacy", FULL)
                if platform == "ios":
                    write_manifest(plugins / "PincerNotifications.appex/PrivacyInfo.xcprivacy", {})
                for package, reasons in (("PincerKit", FULL), ("PincerUI", UI)):
                    write_manifest(resources / f"Pincer_{package}.bundle/PrivacyInfo.xcprivacy", reasons)
                validate_app(app, platform)
                (share_resources / "PrivacyInfo.xcprivacy").unlink()
                with self.assertRaises(FileNotFoundError):
                    validate_app(app, platform)

    def test_missing_package_resource_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            app = Path(folder) / "Pincer.app"
            write_manifest(app / "PrivacyInfo.xcprivacy", FULL)
            write_manifest(app / "PlugIns/PincerShare.appex/PrivacyInfo.xcprivacy", FULL)
            write_manifest(app / "PlugIns/PincerNotifications.appex/PrivacyInfo.xcprivacy", {})
            with self.assertRaises(ValueError):
                validate_app(app, "ios")


if __name__ == "__main__":
    unittest.main()
