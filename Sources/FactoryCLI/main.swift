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
        subcommands: [Validate.self, Start.self, Status.self, Next.self, Submit.self]
    )
}

// MARK: - Shared helpers

/// The local run store under the current directory (`.factory/runs`).
private func runStore() -> RunStore {
    RunStore.local(under: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
}

/// The directory the agent works in (and where deterministic checks run) — the current directory.
private func workspace() -> URL {
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
}

private func encodeJSON<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

/// Load a pipeline workspace and fail fast if the wiring is invalid (prints issues to stderr).
private func loadValidated(_ dir: String) throws
    -> (pipeline: SpecEnvelope<PipelineSpec>, workers: [String: WorkerSpec], checks: [String: CheckSpec]) {
    let bundle = try SpecLoader().loadBundle(at: URL(fileURLWithPath: dir, isDirectory: true))
    let issues = SpecValidator.validate(pipeline: bundle.pipeline.spec, workers: bundle.workers, checks: bundle.checks)
    guard issues.isEmpty else {
        for issue in issues {
            FileHandle.standardError.write(Data("✗ [\(issue.kind.rawValue)] \(issue.message)\n".utf8))
        }
        throw ExitCode.failure
    }
    return bundle
}

// MARK: - validate

struct Validate: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Load a Pipeline + its Workers from <dir> and check the wiring."
    )
    @Argument(help: "Directory containing pipeline.yaml and a workers/ folder.")
    var dir: String

    func run() throws {
        let (env, workers, checks) = try loadValidated(dir)
        print("✓ \(env.metadata.name): valid — \(env.spec.nodes.count) nodes, "
            + "\(env.spec.edges.count) edges, \(workers.count) workers, \(checks.count) checks")
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
        let (env, _, _) = try loadValidated(dir)
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
        let (env, _, _) = try loadValidated(meta.pipelineDir)
        let runnable = Scheduler.runnable(state, env.spec)
        let total = env.spec.nodes.count

        print("run \(runId)  ·  pipeline '\(env.metadata.name)'  ·  "
            + "\(state.completedNodes.count)/\(total) complete")
        func line(_ label: String, _ items: [String]) {
            print("  \(label): \(items.isEmpty ? "—" : items.sorted().joined(separator: ", "))")
        }
        line("completed ", Array(state.completedNodes))
        line("in progress", Array(state.inProgressNodes))
        line("artifacts  ", Array(state.readyArtifacts))
        line("runnable   ", runnable)
        let rework = state.failedChecks.keys.sorted().map { "\($0) (\(state.failedChecks[$0]!.joined(separator: ", ")))" }
        line("rework     ", rework)
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
        let (env, workers, _) = try loadValidated(meta.pipelineDir)
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
}

// MARK: - submit

struct Submit: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Submit an in-progress node's output: validate it, run its gates, advance or rework."
    )
    @Argument(help: "Run id.")
    var runId: String
    @Option(name: .long, help: "Which in-progress node to submit (required if more than one).")
    var node: String?
    @Option(name: .long, parsing: .upToNextOption,
            help: "Artifact Schemas produced (defaults to the Worker's declared produces).")
    var produced: [String] = []
    @Flag(name: .long, help: "Emit the outcome as JSON.")
    var json = false

    func run() throws {
        let store = runStore()
        guard store.exists(runId) else {
            throw ValidationError("no run '\(runId)' (looked in .factory/runs)")
        }
        let meta = try store.meta(of: runId)
        let (env, workers, checks) = try loadValidated(meta.pipelineDir)
        let pipeline = env.spec
        let state = try store.state(of: runId)

        // Resolve the target: it must be a node `next` dispensed (in progress).
        guard !state.inProgressNodes.isEmpty else {
            throw ValidationError("no node in progress — run `factory next \(runId)` first")
        }
        let target: String
        if let node {
            guard state.inProgressNodes.contains(node) else {
                throw ValidationError("node '\(node)' is not in progress "
                    + "(in progress: \(state.inProgressNodes.sorted().joined(separator: ", ")))")
            }
            target = node
        } else if state.inProgressNodes.count == 1 {
            target = state.inProgressNodes.first!
        } else {
            throw ValidationError("multiple nodes in progress — pass --node "
                + "(\(state.inProgressNodes.sorted().joined(separator: ", ")))")
        }

        let worker = workers[target] ?? WorkerSpec()

        // Output validation (engine-enforced, deterministic): the produced Schemas must cover
        // everything the Worker declares it produces. Nothing is reduced on a shortfall.
        let declared = (worker.produces ?? []).map(\.schema)
        let producedSet = produced.isEmpty ? declared : produced
        let missing = declared.filter { !producedSet.contains($0) }
        guard missing.isEmpty else {
            throw ValidationError("output incomplete: '\(target)' did not produce "
                + "\(missing.joined(separator: ", ")) (declared: \(declared.joined(separator: ", ")))")
        }

        // Run the gates. The engine runs the check and reads the result — never the agent.
        let results = CheckRunner(workingDirectory: workspace()).run(worker.checks ?? [], specs: checks)
        let blocking = results.filter(\.isBlockingFailure)

        if blocking.isEmpty {
            try store.append(.nodeCompleted(node: target, producedArtifacts: producedSet), to: runId)
        } else {
            try store.append(.checkFailed(node: target, checks: blocking.map(\.check)), to: runId)
        }

        let nextState = try store.state(of: runId)
        let runnable = Scheduler.runnable(nextState, pipeline)
        try report(target: target, results: results, blocking: blocking, produced: producedSet,
                   done: nextState.completedNodes.count == pipeline.nodes.count, runnable: runnable)
    }

    private func report(target: String, results: [CheckResult], blocking: [CheckResult],
                        produced: [String], done: Bool, runnable: [String]) throws {
        let advanced = blocking.isEmpty
        if json {
            struct Outcome: Encodable {
                var node: String, advanced: Bool, produced: [String]
                var checks: [CheckResult], failed: [String], runnable: [String]
            }
            print(try encodeJSON(Outcome(node: target, advanced: advanced,
                produced: advanced ? produced : [], checks: results,
                failed: blocking.map(\.check), runnable: runnable)))
            return
        }
        if advanced {
            print("✓ \(target) accepted — produced \(produced.isEmpty ? "(nothing)" : produced.joined(separator: ", "))")
            for r in results where r.status == .deferred { print("  · deferred: \(r.check)") }
            if done {
                print("✓ done — all nodes complete")
            } else {
                print("→ runnable: \(runnable.isEmpty ? "—" : runnable.joined(separator: ", "))  ·  factory next \(runId)")
            }
        } else {
            print("✗ \(target) failed \(blocking.count) gate(s) → rework")
            for r in blocking {
                print("  · \(r.check)\(r.exitCode.map { " (exit \($0))" } ?? "")")
                if let out = r.output, !out.isEmpty {
                    print(out.split(separator: "\n").map { "      \($0)" }.joined(separator: "\n"))
                }
            }
            print("→ factory next \(runId)  (re-renders \(target) with the failures as context)")
        }
    }
}
