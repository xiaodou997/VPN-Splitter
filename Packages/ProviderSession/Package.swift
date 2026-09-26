// swift-tools-version: 6.0
// SPDX-License-Identifier: MIT
import PackageDescription

let package = Package(
    name: "ProviderSession", platforms: [.macOS("26.0")],
    products: [.library(name: "ProviderSession", targets: ["ProviderSession"])],
    targets: [
        .target(name: "ProviderSession"),
        .testTarget(name: "ProviderSessionTests", dependencies: ["ProviderSession"])
    ], swiftLanguageModes: [.v6]
)
