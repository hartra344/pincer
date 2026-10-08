#!/usr/bin/env python3
"""Validate source declarations and the actual app/extension resource packaging."""
import argparse
import json
import plistlib
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FULL = {
    "NSPrivacyAccessedAPICategoryUserDefaults": {"CA92.1", "1C8F.1"},
    "NSPrivacyAccessedAPICategorySystemBootTime": {"35F9.1"},
    "NSPrivacyAccessedAPICategoryFileTimestamp": {"C617.1"},
}
UI = {key: value for key, value in FULL.items() if "FileTimestamp" not in key}
UI = {**UI, "NSPrivacyAccessedAPICategoryUserDefaults": {"CA92.1"}}
SOURCES = {
    "Apps/Shared/PrivacyInfo.xcprivacy": FULL,
    "Apps/ShareExtension/Shared/PrivacyInfo.xcprivacy": FULL,
    "Apps/iOSNotificationService/PrivacyInfo.xcprivacy": {},
    "Sources/PincerKit/Resources/PrivacyInfo.xcprivacy": FULL,
    "Sources/PincerUI/Resources/PrivacyInfo.xcprivacy": UI,
}


def validate_manifest(path, expected):
    with Path(path).open("rb") as source:
        value = plistlib.load(source)
    if value.get("NSPrivacyTracking") is not False:
        raise ValueError(f"{path}: tracking declaration changed; review the privacy policy")
    for key in ("NSPrivacyTrackingDomains", "NSPrivacyCollectedDataTypes"):
        if value.get(key) != []:
            raise ValueError(f"{path}: {key} changed; review the privacy disclosures")
    entries = value.get("NSPrivacyAccessedAPITypes", [])
    actual = {entry["NSPrivacyAccessedAPIType"]: set(entry["NSPrivacyAccessedAPITypeReasons"]) for entry in entries}
    if len(entries) != len(actual) or actual != expected:
        raise ValueError(f"{path}: required-reason declarations do not match audited API use")


def validate_sources(root=ROOT):
    for name, expected in SOURCES.items():
        validate_manifest(root / name, expected)


def validate_project(path):
    data = subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(path / "project.pbxproj")])
    objects = json.loads(data)["objects"]
    targets = {obj["name"]: obj for obj in objects.values() if obj.get("isa") == "PBXNativeTarget"}
    for name in ("Pincer-iOS", "Pincer-macOS", "PincerShare-iOS", "PincerShare-macOS", "PincerNotifications-iOS"):
        target = targets[name]
        resources = []
        for phase_id in target["buildPhases"]:
            phase = objects[phase_id]
            if phase["isa"] != "PBXResourcesBuildPhase":
                continue
            for build_file in phase["files"]:
                ref = objects[objects[build_file]["fileRef"]]
                if Path(ref.get("path", "")).name == "PrivacyInfo.xcprivacy":
                    resources.append(ref)
        if len(resources) != 1:
            raise ValueError(f"{name}: expected exactly one privacy manifest in Copy Bundle Resources")


def resource_root(bundle):
    return bundle / "Contents/Resources" if (bundle / "Contents").is_dir() else bundle


def validate_app(app, platform):
    validate_manifest(resource_root(app) / "PrivacyInfo.xcprivacy", FULL)
    plugins = app / ("Contents/PlugIns" if platform == "macos" else "PlugIns")
    expected_names = {"PincerShare.appex"} | ({"PincerNotifications.appex"} if platform == "ios" else set())
    for name in expected_names:
        expected = {} if name == "PincerNotifications.appex" else FULL
        validate_manifest(resource_root(plugins / name) / "PrivacyInfo.xcprivacy", expected)
    # Both package targets must retain their own manifests after copying resources.
    for package, expected in (("PincerKit", FULL), ("PincerUI", UI)):
        matches = [p for p in app.rglob("PrivacyInfo.xcprivacy") if f"Pincer_{package}.bundle" in p.parts]
        if not matches:
            raise ValueError(f"{app}: missing bundled {package} privacy manifest")
        for path in matches:
            validate_manifest(path, expected)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--project", type=Path)
    parser.add_argument("--app", type=Path)
    parser.add_argument("--platform", choices=("ios", "macos"))
    args = parser.parse_args()
    validate_sources(args.root)
    if args.project:
        validate_project(args.project)
    if args.app:
        if not args.platform:
            parser.error("--app requires --platform")
        validate_app(args.app, args.platform)
    print("Release privacy declarations and requested bundle checks passed.")
