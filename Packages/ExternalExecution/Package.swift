// swift-tools-version: 6.0
// SPDX-License-Identifier: MIT
import PackageDescription

let package = Package(
    name: "ExternalExecution", platforms: [.macOS("26.0")],
    products: [.library(name: "ExternalExecution", targets: ["ExternalExecution"]),
               .executable(name: "VPNExternalLease", targets: ["ExternalLease"])],
    dependencies: [.package(path: "../ExternalCore"), .package(path: "../PolicyCore")],
    targets: [
        .target(name: "CExternalRoute", publicHeadersPath: "include"),
        .target(name: "ExternalExecution", dependencies: ["ExternalCore", "PolicyCore", "CExternalRoute"]),
        .executableTarget(name: "ExternalLease", dependencies: ["ExternalExecution", "ExternalCore", "PolicyCore", "CExternalRoute"]),
        .testTarget(name: "ExternalExecutionTests", dependencies: ["ExternalExecution", "ExternalCore", "PolicyCore"])
    ], swiftLanguageModes: [.v6]
)
