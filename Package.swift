// swift-tools-version: 6.0

import PackageDescription

// The new spec-driven Factory engine. The old phase-based engine is preserved under
// legacy/ for reference (ports of its reusable infra — identity, secrets, telemetry,
// artifact store, lock — will be brought over deliberately, not wholesale).
let package = Package(
    name: "factory",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "FactoryModels", targets: ["FactoryModels"]),
        .library(name: "FactoryEngine", targets: ["FactoryEngine"])
    ],
    targets: [
        // Declarative spec types (Codable) + runtime types. No dependencies.
        .target(name: "FactoryModels"),
        // The deterministic engine: spec loader, validator, Scheduler, Reducer.
        .target(name: "FactoryEngine", dependencies: ["FactoryModels"]),
        .testTarget(name: "FactoryEngineTests", dependencies: ["FactoryEngine", "FactoryModels"])
    ]
)
