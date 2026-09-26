// swift-tools-version: 6.0
// SPDX-License-Identifier: MIT
import PackageDescription

let package = Package(
    name: "ProviderConfiguration",
    platforms: [.macOS("26.0")],
    products: [.library(name: "ProviderConfiguration", targets: ["ProviderConfiguration"])],
    dependencies: [.package(path: "../AppCore"), .package(path: "../PolicyCore")],
    targets: [
        .target(name: "ProviderConfiguration", dependencies: ["AppCore", "PolicyCore"]),
        .testTarget(name: "ProviderConfigurationTests", dependencies: ["ProviderConfiguration", "AppCore", "PolicyCore"])
    ]
)
