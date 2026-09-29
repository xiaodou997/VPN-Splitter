// swift-tools-version: 6.0
// SPDX-License-Identifier: MIT
import PackageDescription

let package = Package(
    name: "ExternalFlowWire", platforms: [.macOS("26.0")],
    products: [.library(name: "ExternalFlowWire", targets: ["ExternalFlowWire"])],
    targets: [
        .target(name: "ExternalFlowWire"),
        .testTarget(name: "ExternalFlowWireTests", dependencies: ["ExternalFlowWire"])
    ],
    swiftLanguageModes: [.v6]
)
