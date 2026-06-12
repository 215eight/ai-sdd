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
        subcommands: [Validate.self, Start.self, Status.self, Next.self]
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
        line("completed ", Array(state.completedNodes))
        line("in progress", Array(state.inProgressNodes))
        line("artifacts  ", Array(state.readyArtifacts))
        line("runnable   ", runnable)
        if state.completedNodes.count == total { print("  ✓ done") }
    }
}

// MARK: - next

struct Next: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Render the next runnable Worker's instruction and mark it in progress."
    )
    @Argument(help: "Run id.")
    var runId: String
    @Flag(name: .long, help: "Emit the instruction as JSON instead of Markdown.")
    var json = false
    @Option(name: .long, help: "Pick a specific runnable node instead of the engine's default.")
    var node: String?

    func run() throws {
        let store = runStore()
        guard store.exists(runId) else {
            throw ValidationError("no run '\(runId)' (looked in .factory/runs)")
        }
        let meta = try store.meta(of: runId)
        let (env, workers) = try loadValidated(meta.pipelineDir)
        let pipeline = env.spec
        let state = try store.state(of: runId)

        // Pick the node to dispense: an explicit --node (must be runnable), else the engine's default.
        let pickId: String?
        if let requested = node {
            let runnable = Scheduler.runnable(state, pipeline)
            guard runnable.contains(requested) else {
                throw ValidationError("node '\(requested)' is not runnable now "
                    + "(runnable: \(runnable.isEmpty ? "—" : runnable.joined(separator: ", ")))")
            }
            pickId = requested
        } else {
            pickId = Scheduler.pick(state, pipeline)
        }

        guard let pickId, let pickNode = pipeline.nodes.first(where: { $0.id == pickId }) else {
            try emitIdle(state: state, total: pipeline.nodes.count)
            return
        }

        let worker = pickNode.worker.flatMap { workers[$0] } ?? WorkerSpec()
        var instruction = Renderer.instruction(node: pickNode, worker: worker, state: state)
        instruction.runId = runId

        // Record that this node's work was dispensed — idempotent: re-running `next` before
        // `submit` re-renders the same node and does not append a duplicate event.
        if !state.inProgressNodes.contains(pickId) {
            try store.append(.nodeStarted(node: pickId), to: runId)
        }

        if json {
            print(try encodeJSON(instruction))
        } else {
            print(Renderer.markdown(instruction))
        }
    }

    /// Nothing to dispense: either the Run is done, or it is waiting on gates/inputs.
    private func emitIdle(state: RunState, total: Int) throws {
        let done = state.completedNodes.count == total
        if json {
            print(try encodeJSON(["status": done ? "done" : "idle"]))
        } else {
            print(done ? "✓ done — all nodes complete" : "nothing runnable now (waiting on gates/inputs)")
        }
    }

    private func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
