// swift-tools-version: 6.0
// SPDX-License-Identifier: MIT
import PackageDescription

let package = Package(
    name: "ExternalFlow", platforms: [.macOS("26.0")],
    products: [
        .library(name: "ExternalFlowCore", targets: ["ExternalFlowCore"]),
        .library(name: "ExternalFlowProvider", targets: ["ExternalFlowProvider"])
    ],
    dependencies: [.package(path: "../ExternalCore"), .package(path: "../PolicyCore")],
    targets: [
        .target(name: "ExternalFlowCore", dependencies: ["ExternalCore", "PolicyCore"]),
        .target(name: "ExternalFlowProvider", dependencies: ["ExternalFlowCore"],
            linkerSettings: [.linkedFramework("NetworkExtension", .when(platforms: [.macOS])),
                             .linkedFramework("Network", .when(platforms: [.macOS]))]),
        .testTarget(name: "ExternalFlowCoreTests", dependencies: ["ExternalFlowCore", "ExternalCore", "PolicyCore"])
    ], swiftLanguageModes: [.v6]
)
