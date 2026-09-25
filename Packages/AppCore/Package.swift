// swift-tools-version: 6.0
// SPDX-License-Identifier: MIT
import PackageDescription

let package = Package(
    name: "AppCore",
    platforms: [.macOS("26.0")],
    products: [.library(name: "AppCore", targets: ["AppCore"])],
    dependencies: [.package(path: "../PolicyCore")],
    targets: [
        .target(name: "AppCore", dependencies: ["PolicyCore"]),
        .testTarget(name: "AppCoreTests", dependencies: ["AppCore", "PolicyCore"])
    ],
    swiftLanguageModes: [.v6]
)
