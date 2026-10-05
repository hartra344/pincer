#!/usr/bin/env python3
"""Qualify the actual rendered Last checked timestamp through an isolated XCUI app host."""
import argparse, json, os, re, signal, subprocess, tempfile, uuid
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--destination", required=True, help="Explicit xcodebuild iOS Simulator destination")
parser.add_argument("--timeout", type=int, default=300, help="Per-process fence in seconds")
args = parser.parse_args()
if args.timeout <= 0:
    parser.error("timeout must be positive")
def interrupted(_signal, _frame):
    raise KeyboardInterrupt("Interrupted; stopping only owned process group")
signal.signal(signal.SIGTERM, interrupted)
if "platform=iOS Simulator" not in args.destination:
    parser.error("destination must select platform=iOS Simulator")
repo = Path(__file__).resolve().parent.parent
root = Path(tempfile.mkdtemp(prefix="pincer-lastchecked-app-host-"))
print("Owned harness and results:", root, flush=True)
namespace = "lastchecked-" + uuid.uuid4().hex
selector = "LastCheckedHarnessTests/LastCheckedUITests/testActualFixedSavedTimestampChangesRenderedLabel"
app_id = "chat.pincer.verification." + namespace + ".app"
test_id = "chat.pincer.verification." + namespace + ".tests"
device_match = re.search(r"(?:^|,)\s*id=([0-9A-Fa-f-]{36})(?:,|$)", args.destination)
if not device_match:
    parser.error("destination must include an explicit Simulator id for owned-app cleanup")
device_id = device_match.group(1)

def run(command):
    process = subprocess.Popen(command, start_new_session=True)
    try:
        status = process.wait(timeout=args.timeout)
        if status:
            raise subprocess.CalledProcessError(status, command)
    finally:
        # Only this launched process group; never kill another simulator/app/process.
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=10)

(root / "App").mkdir()
(root / "Tests").mkdir()
(root / "App/App.swift").write_text('import SwiftUI\n@testable import PincerKit\n@testable import PincerUI\n@main struct LastCheckedHarnessApp: App {\n    private let saved: BackgroundRefreshLastCheck\n    init() {\n        let suite = "lastchecked-fixture-" + UUID().uuidString\n        let defaults = UserDefaults(suiteName: suite)!\n        defaults.set(Date().addingTimeInterval(-2), forKey: "pincer.refresh.lastRun")\n        defaults.set("Up to date", forKey: "pincer.refresh.lastResult")\n        saved = BackgroundRefreshLastCheck(defaults: defaults)\n        defaults.removePersistentDomain(forName: suite)\n    }\n    var body: some Scene { WindowGroup { NotificationLastCheckedValue(saved: saved) } }\n}\n')
(root / "Tests/LastCheckedUITests.swift").write_text((repo / "scripts/fixtures/LastCheckedUITests.swift").read_text())
spec = json.loads(r'''{
  "name": "LastCheckedHarness",
  "options": {
    "bundleIdPrefix": "",
    "deploymentTarget": {
      "iOS": "18.0"
    }
  },
  "packages": {
    "Pincer": {
      "path": ""
    }
  },
  "settings": {
    "base": {
      "SWIFT_VERSION": "6.0",
      "GENERATE_INFOPLIST_FILE": "YES",
      "CODE_SIGNING_ALLOWED": "NO",
      "ENABLE_TESTABILITY": "YES",
      "TARGETED_DEVICE_FAMILY": "1,2"
    }
  },
  "targets": {
    "LastCheckedHarnessApp": {
      "type": "application",
      "platform": "iOS",
      "sources": [
        "App"
      ],
      "dependencies": [{"package": "Pincer", "product": "PincerUI"}, {"package": "Pincer", "product": "PincerKit"}],
      "settings": {
        "base": {
          "SWIFT_PACKAGE_NAME": "pincer",
          "OTHER_SWIFT_FLAGS": "$(inherited) -package-name pincer",
          "INFOPLIST_KEY_UIApplicationSceneManifest_Generation": "YES",
          "INFOPLIST_KEY_UILaunchScreen_Generation": "YES"
        }
      }
    },
    "LastCheckedHarnessTests": {
      "type": "bundle.ui-testing",
      "platform": "iOS",
      "sources": [
        "Tests"
      ],
      "dependencies": [{"target": "LastCheckedHarnessApp"}],
      "settings": {
        "base": {
          "TEST_TARGET_NAME": "LastCheckedHarnessApp"
        }
      }
    }
  },
  "schemes": {
    "LastCheckedHarness": {
      "build": {
        "targets": {
          "LastCheckedHarnessApp": "all",
          "LastCheckedHarnessTests": "test"
        }
      },
      "test": {
        "targets": [
          "LastCheckedHarnessTests"
        ],
        "environmentVariables": {
          "PINCER_LAST_CHECKED_APP_HOSTED": "1",
          "PINCER_KEYCHAIN": "memory",
          "PINCER_DRAFTS": "off",
          "PINCER_DEV_NAMESPACE": ""
        }
      }
    }
  }
}''')
spec["targets"]["LastCheckedHarnessApp"]["settings"]["base"]["PRODUCT_BUNDLE_IDENTIFIER"] = app_id
spec["targets"]["LastCheckedHarnessTests"]["settings"]["base"]["PRODUCT_BUNDLE_IDENTIFIER"] = test_id
spec["packages"]["Pincer"]["path"] = str(repo)
spec["options"]["bundleIdPrefix"] = "chat.pincer.verification." + namespace
spec["schemes"]["LastCheckedHarness"]["test"]["environmentVariables"]["PINCER_DEV_NAMESPACE"] = namespace
(root / "project.json").write_text(json.dumps(spec, indent=2))
run(["xcodegen", "generate", "--spec", str(root / "project.json"), "--project", str(root)])
base = ["xcodebuild", "-project", str(root / "LastCheckedHarness.xcodeproj"), "-scheme", "LastCheckedHarness", "-destination", args.destination, "-derivedDataPath", str(root / "build"), "-jobs", "4", "-parallel-testing-enabled", "NO", "CODE_SIGNING_ALLOWED=NO", "-only-testing:" + selector]
enumeration = root / "enumeration.json"
run(base[:1] + ["test"] + base[1:] + ["-enumerate-tests", "-test-enumeration-style", "flat", "-test-enumeration-format", "json", "-test-enumeration-output-path", str(enumeration)])
listing = json.loads(enumeration.read_text())
enabled = [test["identifier"] for value in listing.get("values", []) for test in value.get("enabledTests", [])]
if listing.get("errors") or enabled not in ([selector], [selector + "()"]) or any("SVG" in name.upper() for name in enabled):
    raise RuntimeError("Expected exactly one enabled lifecycle test and zero SVG: " + repr(enabled))
result = root / "result.xcresult"
try:
    run(base[:1] + ["test-without-building"] + base[1:] + [
        "-test-timeouts-enabled", "YES",
        "-default-test-execution-time-allowance", "60",
        "-maximum-test-execution-time-allowance", "60",
        "-collect-test-diagnostics", "never", "-resultBundlePath", str(result)])
finally:
    # Explicit destination and unique bundle IDs only; no booted/global simulator cleanup.
    for owned_id in (app_id, test_id + ".xctrunner"):
        try:
            subprocess.run(["xcrun", "simctl", "terminate", device_id, owned_id],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
        except (subprocess.TimeoutExpired, OSError):
            print("Owned-app cleanup did not complete within its bound", flush=True)
summary_file = root / "summary.json"
with summary_file.open("w") as output:
    subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result)], stdout=output, check=True, timeout=30)
summary = json.loads(summary_file.read_text())
if summary.get("passedTests") != 1 or summary.get("failedTests") != 0 or summary.get("skippedTests") != 0:
    raise RuntimeError("Lifecycle test must actually pass, never skip: " + repr(summary))
print("PASS: one actual app-hosted lifecycle test; zero skipped/SVG. Results retained:", root)
