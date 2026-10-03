// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Pincer",
    defaultLocalization: "en",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "PincerKit", targets: ["PincerKit"]),
        .library(name: "PincerUI", targets: ["PincerUI"]),
        .library(name: "PincerPush", targets: ["PincerPush"]),
    ],
    targets: [
        // Gateway protocol client, identity, and observable stores. No UI, no node/host capabilities.
        .target(name: "PincerKit", dependencies: ["PincerPush"]),
        // Web Push decryption and payload parsing, shared with the iOS Notification Service Extension.
        .target(name: "PincerPush"),
        // Shared SwiftUI for macOS and iOS.
        .target(name: "PincerUI", dependencies: ["PincerKit"], exclude: ["SECURE_FORM_UI_SPEC.md"], resources: [.process("Resources")]),
        // Development entry point so the macOS app can be built with SwiftPM alone.
        .executableTarget(name: "PincerMacDev", dependencies: ["PincerUI"]),
        // Self-checks runnable without XCTest (`swift run PincerChecks`).
        .executableTarget(name: "PincerChecks", dependencies: ["PincerKit", "PincerPush"]),
        // Unit tests (`swift test`): pure logic only, no sockets, Keychain or shared defaults.
        .testTarget(name: "PincerKitTests", dependencies: ["PincerKit"]),
        // UI-layer tests (streaming probe, transcript rendering). macOS-hosted like the kit tests.
        .testTarget(name: "PincerUITests", dependencies: ["PincerUI", "PincerKit"]),
    ]
)
