// swift-tools-version: 6.0
// SPDX-License-Identifier: MIT
import PackageDescription

let package = Package(
    name: "WireGuardSupport",
    platforms: [.macOS("26.0")],
    products: [.library(name: "WireGuardSupport", targets: ["WireGuardSupport"])],
    targets: [
        .target(name: "WireGuardSupport"),
        .testTarget(name: "WireGuardSupportTests", dependencies: ["WireGuardSupport"])
    ],
    swiftLanguageModes: [.v6]
)
