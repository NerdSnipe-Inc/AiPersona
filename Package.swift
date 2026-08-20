// swift-tools-version: 5.10

import Foundation
import PackageDescription

// Monorepo: sibling packages when present next to this repo (same pattern as
// AIChatKitMLX/Package.swift). SPI / standalone clone: GitHub URLs when SPI_PROCESSING is set or
// the sibling is missing.

private let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

private func siblingOrRemote(
    siblingRelativePath: String,
    url: String,
    from version: Version
) -> Package.Dependency {
    let siblingManifest = packageDirectory
        .appendingPathComponent(siblingRelativePath)
        .standardized
        .appendingPathComponent("Package.swift")

    let forceRemote = ProcessInfo.processInfo.environment["SPI_PROCESSING"] != nil
        || ProcessInfo.processInfo.environment["FORCE_REMOTE_PACKAGES"] != nil

    if !forceRemote, FileManager.default.fileExists(atPath: siblingManifest.path) {
        return .package(path: siblingRelativePath)
    }
    return .package(url: url, from: version)
}

let package = Package(
    name: "AiPersona",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "AiPersona", targets: ["AiPersona"]),
    ],
    dependencies: [
        siblingOrRemote(
            siblingRelativePath: "../AIChatKit",
            url: "https://github.com/NerdSnipe-Inc/AIChatKit.git",
            from: "1.0.0"
        ),
        siblingOrRemote(
            siblingRelativePath: "../AIChatKitMLX",
            url: "https://github.com/NerdSnipe-Inc/AIChatKitMLX.git",
            from: "1.0.0"
        ),
    ],
    targets: [
        .target(
            name: "AiPersona",
            dependencies: [
                .product(name: "AIChatCore", package: "AIChatKit"),
                .product(name: "AIChatOpenAI", package: "AIChatKit"),
                .product(name: "AIChatAnthropic", package: "AIChatKit"),
                .product(name: "AIChatMLX", package: "AIChatKitMLX"),
            ],
            path: "Sources/AiPersona"
        ),
        .testTarget(name: "AiPersonaTests", dependencies: ["AiPersona"], path: "Tests/AiPersonaTests"),
    ]
)
