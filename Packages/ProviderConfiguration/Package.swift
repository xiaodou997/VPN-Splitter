// swift-tools-version: 6.0
// SPDX-License-Identifier: MIT
import PackageDescription

let package = Package(
    name: "ProviderConfiguration",
    platforms: [.macOS(.v13)],
    products: [.library(name: "ProviderConfiguration", targets: ["ProviderConfiguration"])],
    targets: [
        .target(name: "ProviderConfiguration"),
        .testTarget(name: "ProviderConfigurationTests", dependencies: ["ProviderConfiguration"])
    ]
)
