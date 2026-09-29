// swift-tools-version: 6.0
// SPDX-License-Identifier: MIT
import PackageDescription
let package = Package(name: "ExternalControl", platforms: [.macOS("26.0")],
    products: [.library(name: "ExternalControl", targets: ["ExternalControl"])],
    targets: [
        .target(name: "ExternalControl", linkerSettings: [
            .linkedFramework("Security", .when(platforms: [.macOS])),
            .linkedFramework("ServiceManagement", .when(platforms: [.macOS]))]),
        .testTarget(name: "ExternalControlTests", dependencies: ["ExternalControl"])
    ], swiftLanguageModes: [.v6])
