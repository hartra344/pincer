import CoreGraphics
import Foundation
import CryptoKit
import ImageIO
import Network
import Observation
import PincerKit
import PincerPush
import SQLite3
import Synchronization
import UniformTypeIdentifiers
import UserNotifications

// Self-checks that run without XCTest (unavailable with Command Line Tools only).
//   swift run PincerChecks                  → unit suite (offline; also --skip-intent-checks to leave out
//     the slow Shortcuts & Siri checks)
//   swift run PincerChecks --demo           → built-in demo: --demo-core, then --demo-extras
//     (each half also runs alone; a mode flag never runs the unit suite)
//   swift run PincerChecks --live URL TOKEN → end-to-end against a (mock) Gateway: --live-core, then
//     --live-extras (each half also runs alone with its own URL TOKEN, against a fresh mock)
//   swift run PincerChecks --live-no-usage URL TOKEN → a Gateway without usage (mock with MOCK_NO_USAGE=1)
//   swift run PincerChecks --live-no-reply-to URL TOKEN → a Gateway without replyToId (mock with MOCK_NO_REPLY_TO=1)
//   swift run PincerChecks --live-scope-upgrade URL TOKEN → operator.admin upgrade fallback
//     (mock with MOCK_PAIRING=auto MOCK_LEGACY_PAIRING=1)
//   swift run PincerChecks --live-reconnect URL TOKEN → only the #202 reconnect/bootstrap checks (fresh mock)
//   swift run PincerChecks --perf-smoke     → only the message index perf smoke, budgets enforced (run it alone)
//   swift run PincerChecks --memory-probe → footprint after opening 20 chats × 5k items (numbers only)
//   swift run PincerChecks --memory-probe-20k-fill → peak footprint of the background full fill of a 20k-item chat
//   swift run PincerChecks --memory-probe-20k → footprint of one 20k-item chat: open, then leave (numbers only)
//   swift run -c release PincerChecks --perf → message index at 20 chats × 20k messages
//   add --skip-perf-budgets to only report the perf smoke timings, failing just on clearly broken
//     ones (scripts/run-checks.sh passes it to every run it starts side by side, since they share the CPU)
// The suites and their sections are listed in Registry.swift.
// Secrets always stay in memory here (no PINCER_KEYCHAIN needed), so checks never touch or
// prompt for the real Keychain.

// First, before anything reads or writes a secret.
Keychain.useInMemoryStore()
PushKeyStore.useInMemoryStore()

var failures = 0
var passes = 0


// Drafts go to a scratch folder so checks never touch the real ones.
let draftsRoot = FileManager.default.temporaryDirectory.appending(path: "pincer-checks-drafts-\(UUID().uuidString)")
setenv("PINCER_DRAFTS_DIR", draftsRoot.path(percentEncoded: false), 1)
// Same for the transcript cache and the message search index inside it (demo and live runs fill
// them), so concurrent runs (and `swift test`) never share one.
let cacheRoot = FileManager.default.temporaryDirectory.appending(path: "pincer-checks-cache-\(UUID().uuidString)")
setenv("PINCER_CACHE_DIR", cacheRoot.path(percentEncoded: false), 1)
// And for unsent messages (the outbox).
let outboxRoot = FileManager.default.temporaryDirectory.appending(path: "pincer-checks-outbox-\(UUID().uuidString)")
setenv("PINCER_OUTBOX_DIR", outboxRoot.path(percentEncoded: false), 1)

let arguments = CommandLine.arguments
func liveTarget(_ flag: String) -> (url: String, token: String)? {
    guard let index = arguments.firstIndex(of: flag), arguments.count > index + 2 else { return nil }
    return (arguments[index + 1], arguments[index + 2])
}

func cleanUp() {
    try? FileManager.default.removeItem(at: draftsRoot)
    try? FileManager.default.removeItem(at: cacheRoot)
    try? FileManager.default.removeItem(at: outboxRoot)
}

// Pick the mode first; a mode flag runs only its own suites, and no flag runs the unit suite.
if arguments.contains("--perf-smoke") {
    await runSections(Suites.perfSmoke)
    print("\n\(passes) passed, \(failures) failed")
    cleanUp()
    exit(failures == 0 ? 0 : 1)
}

let liveAll = liveTarget("--live")
let liveCore = liveAll ?? liveTarget("--live-core")
let liveExtras = liveAll ?? liveTarget("--live-extras")
let liveScopeUpgrade = liveTarget("--live-scope-upgrade")
let liveReconnect = liveTarget("--live-reconnect")
let liveNoUsage = liveTarget("--live-no-usage")
let liveNoReplyTo = liveTarget("--live-no-reply-to")
let perf = arguments.contains("--perf")
let memoryProbe = arguments.contains("--memory-probe")
let memoryProbe20k = arguments.contains("--memory-probe-20k")
let memoryProbe20kFill = arguments.contains("--memory-probe-20k-fill")
let demoAll = arguments.contains("--demo")
let demoCore = demoAll || arguments.contains("--demo-core")
let demoExtras = demoAll || arguments.contains("--demo-extras")
let modeSelected = liveCore != nil || liveExtras != nil || liveScopeUpgrade != nil || liveReconnect != nil || liveNoUsage != nil
    || liveNoReplyTo != nil || perf || memoryProbe || memoryProbe20k || memoryProbe20kFill || demoCore || demoExtras

if !modeSelected {
    await runSections(Suites.unit(skipIntentChecks: arguments.contains("--skip-intent-checks")))
}
if let (url, token) = liveCore { await runSections(Suites.liveCore, url: url, token: token) }
if let (url, token) = liveExtras { await runSections(Suites.liveExtras, url: url, token: token) }
if let (url, token) = liveScopeUpgrade { await runSections(Suites.liveScopeUpgrade, url: url, token: token) }
if let (url, token) = liveReconnect { await runSections(Suites.liveReconnect, url: url, token: token) }
if perf { await runSections(Suites.perf) }
if memoryProbe20k { await runSections([Section("Memory probe (one 20k-item chat: open, leave)") { await runMemoryProbe20k() }]) }
if memoryProbe20kFill { await runSections([Section("Memory probe (headless full fill of a 20k-item chat)") { await runMemoryProbe20kFill() }]) }
if memoryProbe { await runSections([Section("Memory probe (20 chats × 5k items)") { await runMemoryProbe() }]) }
if let (url, token) = liveNoUsage { await runSections(Suites.liveNoUsage, url: url, token: token) }
if let (url, token) = liveNoReplyTo { await runSections(Suites.liveNoReplyTo, url: url, token: token) }
if demoCore { await runSections(Suites.demoCore) }
if demoExtras { await runSections(Suites.demoExtras) }

print("Keychain isolation")
check(Keychain.isInMemory && KeychainMode.isInMemory, "secrets use the in-memory store")
check(KeychainMode.realKeychainCalls == 0, "no real Keychain (SecItem) calls during checks")

print("\n\(passes) passed, \(failures) failed")
cleanUp()
exit(failures == 0 ? 0 : 1)
