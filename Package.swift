// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Release builds link Sparkle 2 for updates (STARNOTCH_SPARKLE=1, see RELEASING.md). Everyday
// builds and the tests don't, so they need no network and no third-party code.
let sparkle = ProcessInfo.processInfo.environment["STARNOTCH_SPARKLE"] == "1"
let screenContext: [SwiftSetting] = []
let taraMemory: [SwiftSetting] = []

let package = Package(
    name: "Starnotch",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        // The app as a library: connectors (separate packages) link it into their own build.
        .library(name: "NotchCore", targets: ["NotchCore"]),
        .library(name: "NotchKit", targets: ["NotchKit"]),
        .executable(name: "Starnotch", targets: ["Starnotch"]),
    ],
    dependencies: sparkle ? [.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")] : [],
    targets: [
        // Pure logic without AppKit: geometry, wheel math, parsers, config, the connector API.
        .target(name: "NotchCore", swiftSettings: screenContext + taraMemory),
        // The menu bar app (AppKit + SwiftUI): island, wheel, modules, settings.
        .target(name: "NotchKit", dependencies: ["NotchCore"] + (sparkle ? [.product(name: "Sparkle", package: "Sparkle")] : []),
                swiftSettings: screenContext + taraMemory),
        // The public app: the kit without connectors.
        .executableTarget(name: "Starnotch", dependencies: ["NotchKit"]),
        // Tara's free brain: one call to Apple's on-device model per run, for the sidecar (agent/claude.py).
        .executableTarget(name: "AppleModel"),
        // Foundation helpers for the tests. The Command Line Tools ship Swift Testing without the
        // Foundation cross-import overlay, so test files must not import Foundation themselves.
        .target(
            name: "TestSupport",
            dependencies: ["NotchCore"],
            path: "Tests/TestSupport"
        ),
        .testTarget(name: "NotchCoreTests", dependencies: ["NotchCore", "TestSupport"], swiftSettings: taraMemory),
    ]
)
