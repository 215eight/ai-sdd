// swift-tools-version: 6.0

import PackageDescription

// The new spec-driven ai-sdd engine (modeled internally on a software-factory analogy). The old
// phase-based engine is preserved under legacy/ for reference.
let package = Package(
    name: "ai-sdd",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "AISDDModels", targets: ["AISDDModels"]),
        .library(name: "AISDDEngine", targets: ["AISDDEngine"]),
        .executable(name: "ai-sdd", targets: ["AISDDCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0")
    ],
    targets: [
        // Declarative spec types (Codable) + runtime types. No dependencies.
        .target(name: "AISDDModels"),
        // The deterministic engine: spec loader (JSON + YAML), validator, Scheduler, Reducer.
        // Embeds the framework skills + the `pre-commit` integrity-hook source as bundle resources
        // (copied via symlinks under Resources/ that point at the repo-root source of truth) so the
        // binary can reconcile a repo with no source clone. Read back through `Bundle.module`.
        .target(
            name: "AISDDEngine",
            dependencies: ["AISDDModels", .product(name: "Yams", package: "Yams")],
            resources: [
                .copy("Resources/skills"),
                .copy("Resources/hooks")
            ]
        ),
        // The CLI the agent drives (Mode B): validate / start / next / submit.
        .executableTarget(
            name: "AISDDCLI",
            dependencies: [
                "AISDDEngine",
                "AISDDModels",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .testTarget(name: "AISDDEngineTests", dependencies: ["AISDDEngine", "AISDDModels"])
    ]
)
