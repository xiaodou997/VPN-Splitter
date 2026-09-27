// swift-tools-version: 6.0
// SPDX-License-Identifier: MIT
import PackageDescription

let package = Package(
    name: "ExternalCore", platforms: [.macOS("26.0")],
    products: [.library(name: "ExternalCore", targets: ["ExternalCore"]),
               .executable(name: "VPNExternalPreview", targets: ["ExternalPreview"])],
    dependencies: [.package(path: "../PolicyCore")],
    targets: [
        .target(name: "ExternalCore", dependencies: ["PolicyCore"],
            linkerSettings: [.linkedFramework("SystemConfiguration", .when(platforms: [.macOS]))]),
        .executableTarget(name: "ExternalPreview", dependencies: ["ExternalCore", "PolicyCore"],
            linkerSettings: [.linkedFramework("SystemConfiguration", .when(platforms: [.macOS]))]),
        .testTarget(name: "ExternalCoreTests", dependencies: ["ExternalCore", "PolicyCore"])
    ], swiftLanguageModes: [.v6]
)
