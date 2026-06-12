import Foundation
import ArgumentParser
import FactoryModels
import FactoryEngine

// The `factory` CLI: the deterministic engine an agent drives interactively. The engine plans
// (what's runnable, what gates pass) and advances state; the agent does the work via skills.
// Commands so far: validate / start / status. `next` and `submit` follow.
@main
struct Factory: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "factory",
        abstract: "Spec-driven software factory engine (deterministic planner; agents do the work via skills).",
        subcommands: [Validate.self, Start.self, Status.self]
    )
}

// MARK: - Shared helpers

/// The local run store under the current directory (`.factory/runs`).
private func runStore() -> RunStore {
    RunStore.local(under: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
}

/// Load a pipeline workspace and fail fast if the wiring is invalid (prints issues to stderr).
private func loadValidated(_ dir: String) throws -> (SpecEnvelope<PipelineSpec>, [String: WorkerSpec]) {
    let bundle = try SpecLoader().loadBundle(at: URL(fileURLWithPath: dir, isDirectory: true))
    let issues = SpecValidator.validate(pipeline: bundle.pipeline.spec, workers: bundle.workers)
    guard issues.isEmpty else {
        for issue in issues {
            FileHandle.standardError.write(Data("✗ [\(issue.kind.rawValue)] \(issue.message)\n".utf8))
        }
        throw ExitCode.failure
    }
    return (bundle.pipeline, bundle.workers)
}

// MARK: - validate

struct Validate: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Load a Pipeline + its Workers from <dir> and check the wiring."
    )
    @Argument(help: "Directory containing pipeline.yaml and a workers/ folder.")
    var dir: String

    func run() throws {
        let (env, workers) = try loadValidated(dir)
        print("✓ \(env.metadata.name): valid — \(env.spec.nodes.count) nodes, "
            + "\(env.spec.edges.count) edges, \(workers.count) workers")
    }
}

// MARK: - start

struct Start: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Validate a pipeline and start a Run on it.")
    @Argument(help: "Directory containing pipeline.yaml and a workers/ folder.")
    var dir: String
    @Option(name: .long, help: "Run id (generated if omitted).")
    var id: String?

    func run() throws {
        let (env, _) = try loadValidated(dir)
        let runId = id ?? "run-\(UUID().uuidString.prefix(8).lowercased())"
        let store = runStore()
        guard !store.exists(runId) else { throw ValidationError("run '\(runId)' already exists") }

        let pipelineDir = URL(fileURLWithPath: dir, isDirectory: true).standardizedFileURL.path
        try store.create(runId: runId, pipelineDir: pipelineDir)
        try store.append(.runStarted(seedArtifacts: []), to: runId)

        print("started \(runId) on pipeline '\(env.metadata.name)'")
        print("→ factory status \(runId)")
    }
}

// MARK: - status

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show a Run's state and what is runnable now.")
    @Argument(help: "Run id.")
    var runId: String

    func run() throws {
        let store = runStore()
        guard store.exists(runId) else {
            throw ValidationError("no run '\(runId)' (looked in .factory/runs)")
        }
        let meta = try store.meta(of: runId)
        let state = try store.state(of: runId)
        let bundle = try SpecLoader().loadBundle(at: URL(fileURLWithPath: meta.pipelineDir, isDirectory: true))
        let runnable = Scheduler.runnable(state, bundle.pipeline.spec)
        let total = bundle.pipeline.spec.nodes.count

        print("run \(runId)  ·  pipeline '\(bundle.pipeline.metadata.name)'  ·  "
            + "\(state.completedNodes.count)/\(total) complete")
        func line(_ label: String, _ items: [String]) {
            print("  \(label): \(items.isEmpty ? "—" : items.sorted().joined(separator: ", "))")
        }
        line("completed", Array(state.completedNodes))
        line("artifacts", Array(state.readyArtifacts))
        line("runnable ", runnable)
        if state.completedNodes.count == total { print("  ✓ done") }
    }
}
