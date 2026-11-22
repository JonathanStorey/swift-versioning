// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "swift-versioning",
    // Floors match the minimum deployment targets of the Swift Testing module.
    platforms: [
        .macOS(.v10_15),
        .iOS(.v13),
        .tvOS(.v13),
        .watchOS(.v6),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "Versioning", targets: ["Versioning"]),
    ],
    targets: [
        .target(name: "Versioning"),
        .testTarget(
            name: "VersioningTests",
            dependencies: ["Versioning"]
        ),
    ]
)
