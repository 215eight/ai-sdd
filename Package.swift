// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ai-sdd",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "SDDModels", targets: ["SDDModels"]),
        .library(name: "SDDCore", targets: ["SDDCore"]),
        .library(name: "SDDMCP", targets: ["SDDMCP"]),
        .executable(name: "sdd", targets: ["SDDCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0")
    ],
    targets: [
        .target(name: "SDDModels"),
        .target(
            name: "SDDCore",
            dependencies: ["SDDModels"]
        ),
        .target(
            name: "SDDMCP",
            dependencies: ["SDDCore", "SDDModels"]
        ),
        .executableTarget(
            name: "SDDCLI",
            dependencies: [
                "SDDCore",
                "SDDModels",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .testTarget(
            name: "SDDCoreTests",
            dependencies: ["SDDCore", "SDDModels"]
        )
    ]
)
