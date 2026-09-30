#!/usr/bin/env bash
# Writes a shared Xcode scheme that builds only the UI and Kit libraries and their tests.
# Pincer-Package also builds PincerChecks and PincerMacDev, which are macOS-only.
set -euo pipefail
dir="$(cd "$(dirname "$0")/.." && pwd)/.swiftpm/xcode/xcshareddata/xcschemes"
mkdir -p "$dir"
ref() {
  cat <<REF
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "$1"
               BuildableName = "$2"
               BlueprintName = "$1"
               ReferencedContainer = "container:">
            </BuildableReference>
REF
}
{
  cat <<'HEAD'
<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "1600" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "NO" buildForProfiling = "NO" buildForArchiving = "NO" buildForAnalyzing = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "PincerUI"
               BuildableName = "PincerUI"
               BlueprintName = "PincerUI"
               ReferencedContainer = "container:">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference skipped = "NO">
HEAD
  ref PincerUITests PincerUITests
  cat <<'TAIL'
         </TestableReference>
      </Testables>
   </TestAction>
</Scheme>
TAIL
} > "$dir/PincerUITests-iOS.xcscheme"
