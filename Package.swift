// swift-tools-version: 6.1
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 GIGNIT LLC and the Leap contributors
import PackageDescription

let package = Package(
    name: "leap",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "leap", targets: ["leap"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
    ],
    targets: [
        .target(
            name: "LeapCore",
            path: "Sources/LeapCore",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AppKit"),
                .linkedFramework("ScreenCaptureKit"),
            ]
        ),
        .executableTarget(
            name: "leap",
            dependencies: [
                "LeapCore",
                .product(name: "MCP", package: "swift-sdk"),
            ],
            path: "Sources/leap"
        ),
        .testTarget(
            name: "LeapCoreTests",
            dependencies: ["LeapCore"],
            path: "Tests/LeapCoreTests"
        ),
    ],
    // Swift 6 strict concurrency is not adopted yet; the manifest needs 6.1 for the MCP SDK.
    swiftLanguageModes: [.v5]
)
