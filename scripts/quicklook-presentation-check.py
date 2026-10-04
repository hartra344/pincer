#!/usr/bin/env python3
"""Run only the real app-hosted Quick Look lifecycle probe, never the package suite."""
import argparse, json, os, signal, subprocess, tempfile, uuid
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
root = Path(tempfile.mkdtemp(prefix="pincer-quicklook-app-host-"))
print("Owned harness and results:", root, flush=True)
namespace = "quicklook-" + uuid.uuid4().hex
selector = "QuickLookHarnessTests/QuickLookHarnessTests/actualQuickLookPresentationRetainsFileUntilDismissal()"

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
(root / "App/App.swift").write_text('import SwiftUI\n@main struct QuickLookHarnessApp: App { var body: some Scene { WindowGroup { Text("Quick Look verification") } } }\n')
source = (repo / "Tests/PincerUITests/QuickLookPresentationLifecycleHostedTests.swift").read_text()
needle = "@MainActor extension TranscriptUIKitHostedTests {"
if source.count(needle) != 1:
    raise RuntimeError("Committed probe extension changed; review mapping before running")
source = source.replace(needle, "@MainActor @Suite struct QuickLookHarnessTests {")
(root / "Tests/QuickLookHarnessTests.swift").write_text(source)
(root / "Tests/Support.swift").write_text('import Foundation\n@MainActor func eventually(timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {\n let deadline=ContinuousClock.now.advanced(by:timeout)\n repeat { if condition() { return true }; if Task.isCancelled { return false }; try? await Task.sleep(for: .milliseconds(10)) } while ContinuousClock.now < deadline\n return !Task.isCancelled && condition()\n}\n')
spec = json.loads(r'''{
  "name": "QuickLookHarness",
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
    "QuickLookHarnessApp": {
      "type": "application",
      "platform": "iOS",
      "sources": [
        "App"
      ],
      "settings": {
        "base": {
          "INFOPLIST_KEY_UIApplicationSceneManifest_Generation": "YES",
          "INFOPLIST_KEY_UILaunchScreen_Generation": "YES"
        }
      }
    },
    "QuickLookHarnessTests": {
      "type": "bundle.unit-test",
      "platform": "iOS",
      "sources": [
        "Tests"
      ],
      "dependencies": [
        {
          "target": "QuickLookHarnessApp"
        },
        {
          "package": "Pincer",
          "product": "PincerUI"
        },
        {
          "package": "Pincer",
          "product": "PincerKit"
        }
      ],
      "settings": {
        "base": {
          "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/QuickLookHarnessApp.app/QuickLookHarnessApp",
          "BUNDLE_LOADER": "$(TEST_HOST)"
        }
      }
    }
  },
  "schemes": {
    "QuickLookHarness": {
      "build": {
        "targets": {
          "QuickLookHarnessApp": "all",
          "QuickLookHarnessTests": "test"
        }
      },
      "test": {
        "targets": [
          "QuickLookHarnessTests"
        ],
        "environmentVariables": {
          "PINCER_QUICKLOOK_APP_HOSTED": "1",
          "PINCER_KEYCHAIN": "memory",
          "PINCER_DRAFTS": "off",
          "PINCER_DEV_NAMESPACE": ""
        }
      }
    }
  }
}''')
spec["packages"]["Pincer"]["path"] = str(repo)
spec["options"]["bundleIdPrefix"] = "chat.pincer.verification." + namespace
spec["schemes"]["QuickLookHarness"]["test"]["environmentVariables"]["PINCER_DEV_NAMESPACE"] = namespace
(root / "project.json").write_text(json.dumps(spec, indent=2))
run(["xcodegen", "generate", "--spec", str(root / "project.json"), "--project", str(root)])
base = ["xcodebuild", "-project", str(root / "QuickLookHarness.xcodeproj"), "-scheme", "QuickLookHarness", "-destination", args.destination, "-derivedDataPath", str(root / "build"), "-jobs", "4", "-parallel-testing-enabled", "NO", "CODE_SIGNING_ALLOWED=NO", "-only-testing:" + selector]
enumeration = root / "enumeration.json"
run(base[:1] + ["test"] + base[1:] + ["-enumerate-tests", "-test-enumeration-style", "flat", "-test-enumeration-format", "json", "-test-enumeration-output-path", str(enumeration)])
listing = json.loads(enumeration.read_text())
enabled = [test["identifier"] for value in listing.get("values", []) for test in value.get("enabledTests", [])]
if listing.get("errors") or enabled != [selector] or any("SVG" in name.upper() for name in enabled):
    raise RuntimeError("Expected exactly one enabled lifecycle test and zero SVG: " + repr(enabled))
result = root / "result.xcresult"
run(base[:1] + ["test-without-building"] + base[1:] + ["-collect-test-diagnostics", "never", "-resultBundlePath", str(result)])
summary_file = root / "summary.json"
with summary_file.open("w") as output:
    subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result)], stdout=output, check=True, timeout=30)
summary = json.loads(summary_file.read_text())
if summary.get("passedTests") != 1 or summary.get("failedTests") != 0 or summary.get("skippedTests") != 0:
    raise RuntimeError("Lifecycle test must actually pass, never skip: " + repr(summary))
print("PASS: one actual app-hosted lifecycle test; zero skipped/SVG. Results retained:", root)
