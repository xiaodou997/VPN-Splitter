// swift-tools-version: 6.0
// SPDX-License-Identifier: MIT
import PackageDescription

var products: [Product] = [.library(name: "ManagedSettings", targets: ["ManagedSettings"])]
var targets: [Target] = [
    .target(name: "ManagedSettings", dependencies: ["PolicyCore"]),
    .testTarget(name: "ManagedSettingsTests", dependencies: ["ManagedSettings", "PolicyCore"])
]
#if os(macOS)
products.append(.library(name: "ManagedSettingsApple", targets: ["ManagedSettingsApple"]))
targets += [
    .target(name: "ManagedSettingsApple", dependencies: ["ManagedSettings", "PolicyCore"],
            linkerSettings: [.linkedFramework("NetworkExtension")]),
    .testTarget(name: "ManagedSettingsAppleTests", dependencies: ["ManagedSettingsApple", "ManagedSettings", "PolicyCore"])
]
#endif

let package = Package(
    name: "ManagedSettings", platforms: [.macOS("26.0")], products: products,
    dependencies: [.package(path: "../PolicyCore")], targets: targets, swiftLanguageModes: [.v6]
)
