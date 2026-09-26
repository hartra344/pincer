// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Pincer",
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
        .target(name: "PincerUI", dependencies: ["PincerKit"]),
        // Development entry point so the macOS app can be built with SwiftPM alone.
        .executableTarget(name: "PincerMacDev", dependencies: ["PincerUI"]),
        // Self-checks runnable without XCTest (`swift run PincerChecks`).
        .executableTarget(name: "PincerChecks", dependencies: ["PincerKit", "PincerPush"]),
        // Unit tests (`swift test`): pure logic only, no sockets, Keychain or shared defaults.
        .testTarget(name: "PincerKitTests", dependencies: ["PincerKit"]),
    ]
)
