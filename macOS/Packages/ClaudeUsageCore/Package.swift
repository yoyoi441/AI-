// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ClaudeUsageCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ClaudeUsageCore", targets: ["ClaudeUsageCore"])
    ],
    targets: [
        .target(name: "ClaudeUsageCore"),
        .testTarget(name: "ClaudeUsageCoreTests", dependencies: ["ClaudeUsageCore"]),
        // Plain-Swift sanity check that exercises the same logic as ClaudeUsageCoreTests
        // without XCTest/swift-testing, since this machine only has Command Line Tools
        // (no Xcode) and its Testing.framework/XCTest.framework are stripped down.
        // Xcode itself will use ClaudeUsageCoreTests normally; `swift run CoreSmokeTest`
        // is a fallback that works anywhere the Swift toolchain runs.
        .executableTarget(name: "CoreSmokeTest", dependencies: ["ClaudeUsageCore"])
    ]
)
