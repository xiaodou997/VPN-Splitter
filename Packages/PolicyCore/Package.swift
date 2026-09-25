// swift-tools-version: 6.0
// SPDX-License-Identifier: MIT
import PackageDescription

let package = Package(
    name: "PolicyCore",
    platforms: [.macOS("26.0")],
    products: [.library(name: "PolicyCore", targets: ["PolicyCore"])],
    targets: [
        .target(name: "PolicyCore"),
        .testTarget(name: "PolicyCoreTests", dependencies: ["PolicyCore"])
    ],
    swiftLanguageModes: [.v6]
)
