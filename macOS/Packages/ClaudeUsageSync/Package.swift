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
        .package(url: "https://github.com/firebase/firebase-ios-sdk", from: "11.0.0")
    ],
    targets: [
        .target(
            name: "ClaudeUsageSync",
            dependencies: [
                "ClaudeUsageCore",
                .product(name: "FirebaseCore", package: "firebase-ios-sdk"),
                .product(name: "FirebaseAuth", package: "firebase-ios-sdk"),
                .product(name: "FirebaseFirestore", package: "firebase-ios-sdk")
            ]
        )
    ]
)
