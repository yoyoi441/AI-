// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ClaudeUsageSync",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ClaudeUsageSync", targets: ["ClaudeUsageSync"])
    ],
    dependencies: [
        .package(path: "../ClaudeUsageCore"),
        // Firebase 11.9+ currently resolves grpc-binary 1.69.x. Its distributed
        // macOS binary aborts on some Macs because the POSIX wakeup pipe support
        // required by PollPoller is missing. 11.8 keeps the same Auth/Firestore
        // APIs used here while resolving the stable grpc-binary 1.65.x line.
        .package(url: "https://github.com/firebase/firebase-ios-sdk", exact: "11.8.0")
    ],
    targets: [
        .target(
            name: "ClaudeUsageSync",
            dependencies: [
                "ClaudeUsageCore",
                .product(name: "FirebaseCore", package: "firebase-ios-sdk"),
                .product(name: "FirebaseAuth", package: "firebase-ios-sdk")
            ]
        )
    ]
)
