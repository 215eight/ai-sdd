// swift-tools-version: 6.0

import PackageDescription

// The new spec-driven Factory engine. The old phase-based engine is preserved under
// legacy/ for reference.
let package = Package(
    name: "factory",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "FactoryModels", targets: ["FactoryModels"]),
        .library(name: "FactoryEngine", targets: ["FactoryEngine"]),
        .executable(name: "factory", targets: ["FactoryCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0")
    ],
    targets: [
        // Declarative spec types (Codable) + runtime types. No dependencies.
        .target(name: "FactoryModels"),
        // The deterministic engine: spec loader (JSON + YAML), validator, Scheduler, Reducer.
        .target(
            name: "FactoryEngine",
            dependencies: ["FactoryModels", .product(name: "Yams", package: "Yams")]
        ),
        // The CLI the agent drives (Mode B): validate / start / next / submit.
        .executableTarget(
            name: "FactoryCLI",
            dependencies: [
                "FactoryEngine",
                "FactoryModels",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .testTarget(name: "FactoryEngineTests", dependencies: ["FactoryEngine", "FactoryModels"])
    ]
)
