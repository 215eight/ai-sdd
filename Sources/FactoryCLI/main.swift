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
        version: "ai-sdd factory 0.0.1",
        subcommands: [Validate.self, Start.self, Status.self, Next.self, Submit.self, Check.self, Scope.self, Cover.self]
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

/// A node that expands into a sub-pipeline (a slice).
private func isSlice(_ node: PipelineNode) -> Bool { node.pipeline != nil }

/// Resolve a slice node's sub-pipeline workspace dir, relative to the orchestration workspace.
private func sliceDir(orchestrationDir: String, node: PipelineNode) -> String {
    URL(fileURLWithPath: orchestrationDir, isDirectory: true)
        .appendingPathComponent(node.pipeline ?? "", isDirectory: true)
        .standardizedFileURL.path
}

/// The outcome of advancing one worker node (validating its output + running its gates).
private struct AdvanceOutcome {
    var node: String
    var advanced: Bool
    var produced: [String]
    var results: [CheckResult]
    var blocking: [CheckResult]
    var routedTo: [String]      // §9: producers the rework was routed to (empty unless routed upstream)
    var invalidated: [String]   // nodes invalidated by routing (re-run); for the report
    var escalated: Bool         // gate kept failing past the bound (or no route) → parked for a human
}

/// Validate a worker's output, run its gates, and append the resulting event (wrapped by `scope`
/// so the same logic serves a flat run and a slice's sub-pipeline). Gating is engine-enforced.
/// On a blocking failure the engine decides where the rework goes (§9 / ADR-0011): a *verdict*
/// artifact (a reviewer's) indicts its inputs → route to their producers (or escalate); any other
/// artifact's failure re-runs the node itself.
private func advance(node: String, worker: WorkerSpec, checks: [String: CheckSpec],
                     producedOverride: [String], pipeline: PipelineSpec,
                     workers: [String: WorkerSpec], state: RunState,
                     store: RunStore, runId: String,
                     scope: (RunEvent) -> RunEvent) throws -> AdvanceOutcome {
    let declared = (worker.produces ?? []).map(\.schema)
    let producedSet = producedOverride.isEmpty ? declared : producedOverride
    let missing = declared.filter { !producedSet.contains($0) }
    guard missing.isEmpty else {
        throw ValidationError("output incomplete: '\(node)' did not produce "
            + "\(missing.joined(separator: ", ")) (declared: \(declared.joined(separator: ", ")))")
    }
    let results = CheckRunner(workingDirectory: workspace()).run(worker.checks ?? [], specs: checks)
    let blocking = results.filter(\.isBlockingFailure)

    func outcome(advanced: Bool, routedTo: [String] = [], invalidated: [String] = [],
                 escalated: Bool = false) -> AdvanceOutcome {
        AdvanceOutcome(node: node, advanced: advanced, produced: producedSet, results: results,
                       blocking: blocking, routedTo: routedTo, invalidated: invalidated, escalated: escalated)
    }

    guard !blocking.isEmpty else {
        try store.append(scope(.nodeCompleted(node: node, producedArtifacts: producedSet)), to: runId)
        return outcome(advanced: true)
    }

    let failedChecks = blocking.map(\.check)

    // Route by the failed artifact's shape: a verdict artifact indicts its inputs → upstream rework.
    if let hint = verdictHint(producedSchemas: declared) {
        switch Rework.decide(round: state.reworkRounds[node] ?? 0, failedNode: node,
                             indicted: hint.targets, pipeline: pipeline,
                             produces: producesMap(pipeline: pipeline, workers: workers)) {
        case let .route(routing):
            try store.append(scope(.reworkRouted(
                failedNode: node, producers: routing.producers,
                invalidatedNodes: routing.invalidatedNodes,
                invalidatedArtifacts: routing.invalidatedArtifacts, checks: failedChecks)), to: runId)
            return outcome(advanced: false, routedTo: routing.producers, invalidated: routing.invalidatedNodes)
        case .escalate:
            // Past the bound, or a reject with no resolvable target → escalate to a human.
            try store.append(scope(.escalated(node: node, checks: failedChecks)), to: runId)
            return outcome(advanced: false, escalated: true)
        }
    }

    // Not a verdict artifact: the node's own output is wrong → re-run this node (self-rework).
    try store.append(scope(.checkFailed(node: node, checks: failedChecks)), to: runId)
    return outcome(advanced: false)
}

/// Map each worker node → the artifact schemas it produces (for §9 scope invalidation).
private func producesMap(pipeline: PipelineSpec, workers: [String: WorkerSpec]) -> [String: [String]] {
    var map: [String: [String]] = [:]
    for node in pipeline.nodes {
        if let worker = node.worker.flatMap({ workers[$0] }) {
            map[node.id] = (worker.produces ?? []).map(\.schema)
        }
    }
    return map
}

/// Read a §9 routing hint from a failed node's produced artifact, trying the convention path
/// `.factory/artifacts/<schema>.<ext>`. Returns the first verdict artifact's hint, else nil.
private func verdictHint(producedSchemas: [String]) -> Rework.RoutingHint? {
    let layout = ArtifactLayout(workspace: workspace())
    for schema in producedSchemas {
        for ext in ["yaml", "yml", "json"] {
            guard let text = try? String(contentsOf: layout.file(schema: schema, ext: ext), encoding: .utf8),
                  let hint = try? Rework.routingHint(artifactYAML: text) else { continue }
            return hint
        }
    }
    return nil
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

        print("run \(runId)  ·  pipeline '\(env.metadata.name)'  ·  "
            + "\(state.completedNodes.count)/\(env.spec.nodes.count) complete")
        Self.printLevel(pipeline: env.spec, state: state, dir: meta.pipelineDir, indent: "  ")
        if Scheduler.isComplete(state, env.spec) { print("  ✓ done") }
    }

    /// Print one pipeline level's state, descending into the in-progress slice's sub-pipeline.
    private static func printLevel(pipeline: PipelineSpec, state: RunState, dir: String, indent: String) {
        func line(_ label: String, _ items: [String]) {
            print("\(indent)\(label): \(items.isEmpty ? "—" : items.sorted().joined(separator: ", "))")
        }
        line("completed  ", Array(state.completedNodes))
        line("in progress", Array(state.inProgressNodes))
        line("artifacts  ", Array(state.readyArtifacts))
        line("runnable   ", Scheduler.runnable(state, pipeline))
        line("rework     ", state.failedChecks.keys.sorted().map {
            "\($0) (\(state.failedChecks[$0]!.joined(separator: ", ")))"
        })
        if !state.escalatedNodes.isEmpty { line("escalated  ", Array(state.escalatedNodes)) }
        // Descend into any in-progress slice to show its sub-pipeline progress.
        for sliceId in state.inProgressNodes.sorted() {
            guard let node = pipeline.nodes.first(where: { $0.id == sliceId }), isSlice(node),
                  let sub = try? SpecLoader().loadBundle(at: URL(fileURLWithPath: sliceDir(orchestrationDir: dir, node: node), isDirectory: true))
            else { continue }
            print("\(indent)slice '\(sliceId)'\(node.stack.map { " (stack: \($0))" } ?? "") →")
            printLevel(pipeline: sub.pipeline.spec, state: state.slices[sliceId] ?? RunState(),
                       dir: sliceDir(orchestrationDir: dir, node: node), indent: indent + "    ")
        }
    }
}

// MARK: - check

struct Check: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Validate a structured artifact against a Schema's fields + invariants (a deterministic gate)."
    )
    @Argument(help: "Path to the Schema spec (kind: Schema).")
    var schema: String
    @Argument(help: "Path to the artifact file (YAML/JSON) to validate.")
    var artifact: String

    func run() throws {
        let env = try SpecLoader().loadSchemaYAML(try String(contentsOfFile: schema, encoding: .utf8))
        let artifactText = try String(contentsOfFile: artifact, encoding: .utf8)
        let violations = try SchemaValidator.validate(env.spec, artifactYAML: artifactText)
        guard violations.isEmpty else {
            for v in violations {
                FileHandle.standardError.write(Data("✗ \(v.field): \(v.message)\n".utf8))
            }
            throw ExitCode.failure
        }
        print("✓ \(artifact) satisfies \(env.metadata.name).v\(env.metadata.version ?? 1)")
    }
}

// MARK: - scope

struct Scope: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Verify the working tree's changes stay within a plan's declared file manifest (Tier-2 gate)."
    )
    @Option(name: .long, help: "Plan artifact (YAML) whose `files:` list is the allowed manifest.")
    var plan: String?
    @Option(name: .long, parsing: .upToNextOption, help: "Explicit allowed files (instead of --plan).")
    var files: [String] = []
    @Option(name: .long, help: "Repo directory (default: current).")
    var repo: String?
    @Option(name: .long, help: "Baseline git ref — also include changes committed since it.")
    var baseline: String?

    func run() throws {
        let repoDir = repo ?? FileManager.default.currentDirectoryPath
        let declared = try plan.map { try ScopeChecker.declaredFiles(planYAML: String(contentsOfFile: $0, encoding: .utf8)) } ?? files
        guard !declared.isEmpty else {
            throw ValidationError("no declared files — pass --plan <file with a files: list> or --files")
        }

        // `-uall` lists untracked files individually (a new dir is otherwise collapsed to `dir/`,
        // which would slip new files past the gate). Ignored files (e.g. `.factory/`) stay omitted.
        let porcelain = try git(["status", "--porcelain", "--untracked-files=all"], in: repoDir)
        let committed = baseline.flatMap { try? git(["diff", "--name-status", $0, "HEAD"], in: repoDir) }
        let changed = ScopeChecker.changedFiles(porcelain: porcelain, committed: committed)
        let outOfScope = ScopeChecker.outOfScope(changed: changed, declared: declared)

        guard outOfScope.isEmpty else {
            for file in outOfScope {
                FileHandle.standardError.write(Data("✗ out of scope: \(file)\n".utf8))
            }
            throw ExitCode.failure
        }
        print("✓ \(changed.count) changed file(s), all within the declared manifest")
    }

    private func git(_ args: [String], in dir: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", dir] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - cover

struct Cover: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Verify a review judges every acceptance item the plan declares (a deterministic cross-artifact gate)."
    )
    @Option(name: .long, help: "Plan artifact (YAML) whose `acceptance[].id` list must be covered.")
    var plan: String
    @Option(name: .long, help: "Review artifact (YAML) whose `items[].id` list must cover them.")
    var review: String

    func run() throws {
        let acceptance = try CoverageChecker.acceptanceIDs(planYAML: String(contentsOfFile: plan, encoding: .utf8))
        let reviewed = try CoverageChecker.reviewedIDs(reviewYAML: String(contentsOfFile: review, encoding: .utf8))
        guard !acceptance.isEmpty else {
            throw ValidationError("no acceptance items in \(plan) — nothing to cover (is it a feature-plan artifact?)")
        }
        let uncovered = CoverageChecker.uncovered(acceptance: acceptance, reviewed: reviewed)
        guard uncovered.isEmpty else {
            for id in uncovered {
                FileHandle.standardError.write(Data("✗ acceptance item not reviewed: \(id)\n".utf8))
            }
            throw ExitCode.failure
        }
        print("✓ all \(acceptance.count) acceptance item(s) judged by the review")
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

        // Pick the top-level node: an explicit --node (must be runnable), else the engine's default.
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
            try emitIdle(state: state, pipeline: pipeline)
            return
        }

        if isSlice(pickNode) {
            try dispenseSlice(store: store, orchestrationDir: meta.pipelineDir, slice: pickNode, topState: state)
        } else {
            try dispenseWorker(store: store, node: pickNode,
                               worker: pickNode.worker.flatMap { workers[$0] } ?? WorkerSpec(),
                               state: state, slice: nil, stack: nil, scope: { $0 })
        }
    }

    /// Descend into a slice: mark it in progress at the top level, then dispense the runnable
    /// Worker of its sub-pipeline (scoping that node's events under the slice).
    private func dispenseSlice(store: RunStore, orchestrationDir: String,
                               slice: PipelineNode, topState: RunState) throws {
        if !topState.inProgressNodes.contains(slice.id) {
            try store.append(.nodeStarted(node: slice.id), to: runId)
        }
        let dir = sliceDir(orchestrationDir: orchestrationDir, node: slice)
        let (subEnv, subWorkers, _) = try loadValidated(dir)
        let subState = topState.slices[slice.id] ?? RunState()

        guard let subPick = Scheduler.pick(subState, subEnv.spec),
              let subNode = subEnv.spec.nodes.first(where: { $0.id == subPick }) else {
            try emitIdle(state: subState, pipeline: subEnv.spec)
            return
        }
        try dispenseWorker(store: store, node: subNode,
                           worker: subNode.worker.flatMap { subWorkers[$0] } ?? WorkerSpec(),
                           state: subState, slice: slice.id, stack: slice.stack,
                           scope: { .scoped(slice: slice.id, event: $0) })
    }

    /// Render a Worker node and mark it in progress. Idempotent — re-running `next` before
    /// `submit` re-renders the same node and appends no duplicate event.
    private func dispenseWorker(store: RunStore, node: PipelineNode, worker: WorkerSpec,
                                state: RunState, slice: String?, stack: String?,
                                scope: (RunEvent) -> RunEvent) throws {
        if !state.inProgressNodes.contains(node.id) {
            try store.append(scope(.nodeStarted(node: node.id)), to: runId)
        }
        var instruction = Renderer.instruction(node: node, worker: worker, state: state,
                                               slice: slice, stack: stack)
        instruction.runId = runId
        print(json ? try encodeJSON(instruction) : Renderer.markdown(instruction))
    }

    /// Nothing to dispense: the pipeline is done, parked on a human escalation, or waiting on inputs.
    private func emitIdle(state: RunState, pipeline: PipelineSpec) throws {
        let done = Scheduler.isComplete(state, pipeline)
        let escalated = state.escalatedNodes.sorted()
        if json {
            var status: [String: String] = ["status": done ? "done" : (escalated.isEmpty ? "idle" : "escalated")]
            if !escalated.isEmpty { status["escalated"] = escalated.joined(separator: ",") }
            print(try encodeJSON(status))
        } else if done {
            print("✓ done — all nodes complete")
        } else if !escalated.isEmpty {
            print("⚠ parked for a human — escalated: \(escalated.joined(separator: ", ")) "
                + "(gate failed past \(Rework.maxRounds) rework round(s))")
        } else {
            print("nothing runnable now (waiting on gates/inputs)")
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

        // Resolve the in-progress top-level node `next` dispensed.
        guard !state.inProgressNodes.isEmpty else {
            throw ValidationError("no node in progress — run `factory next \(runId)` first")
        }
        let topTarget = try resolve(node, among: state.inProgressNodes, level: "")
        let topNode = pipeline.nodes.first { $0.id == topTarget }!

        if isSlice(topNode) {
            try submitSlice(store: store, orchestrationDir: meta.pipelineDir,
                            slice: topNode, topPipeline: pipeline)
        } else {
            let outcome = try advance(node: topTarget, worker: workers[topTarget] ?? WorkerSpec(),
                                      checks: checks, producedOverride: produced,
                                      pipeline: pipeline, workers: workers, state: state,
                                      store: store, runId: runId, scope: { $0 })
            try report(outcome: outcome, slice: nil, sliceCompleted: false,
                       topPipeline: pipeline, topState: try store.state(of: runId))
        }
    }

    /// Advance the active Worker inside a slice's sub-pipeline; when that finishes the whole
    /// sub-pipeline, complete the slice at the top level so its dependents unlock.
    private func submitSlice(store: RunStore, orchestrationDir: String,
                             slice: PipelineNode, topPipeline: PipelineSpec) throws {
        let dir = sliceDir(orchestrationDir: orchestrationDir, node: slice)
        let (subEnv, subWorkers, subChecks) = try loadValidated(dir)
        let subState = (try store.state(of: runId)).slices[slice.id] ?? RunState()
        guard !subState.inProgressNodes.isEmpty else {
            throw ValidationError("slice '\(slice.id)': no node in progress — run `factory next \(runId)`")
        }
        let subTarget = try resolve(node, among: subState.inProgressNodes, level: "slice '\(slice.id)': ")

        let outcome = try advance(node: subTarget, worker: subWorkers[subTarget] ?? WorkerSpec(),
                                  checks: subChecks, producedOverride: produced,
                                  pipeline: subEnv.spec, workers: subWorkers, state: subState,
                                  store: store, runId: runId, scope: { .scoped(slice: slice.id, event: $0) })

        // If the sub-pipeline is now fully complete, the slice node completes at the top level.
        var sliceCompleted = false
        let afterSub = (try store.state(of: runId)).slices[slice.id] ?? RunState()
        if outcome.advanced && Scheduler.isComplete(afterSub, subEnv.spec) {
            try store.append(.nodeCompleted(node: slice.id, producedArtifacts: []), to: runId)
            sliceCompleted = true
        }
        try report(outcome: outcome, slice: slice.id, sliceCompleted: sliceCompleted,
                   topPipeline: topPipeline, topState: try store.state(of: runId))
    }

    /// Pick the target among in-progress nodes: an explicit --node (must be in progress), the
    /// sole in-progress node, or an error asking which.
    private func resolve(_ requested: String?, among inProgress: Set<String>, level: String) throws -> String {
        if let requested {
            guard inProgress.contains(requested) else {
                throw ValidationError("\(level)node '\(requested)' is not in progress "
                    + "(in progress: \(inProgress.sorted().joined(separator: ", ")))")
            }
            return requested
        }
        if inProgress.count == 1 { return inProgress.first! }
        throw ValidationError("\(level)multiple nodes in progress — pass --node "
            + "(\(inProgress.sorted().joined(separator: ", ")))")
    }

    private func report(outcome: AdvanceOutcome, slice: String?, sliceCompleted: Bool,
                        topPipeline: PipelineSpec, topState: RunState) throws {
        let label = slice.map { "\($0)/\(outcome.node)" } ?? outcome.node
        let runnable = Scheduler.runnable(topState, topPipeline)
        if json {
            struct Outcome: Encodable {
                var node: String, slice: String?, advanced: Bool, sliceCompleted: Bool
                var produced: [String], checks: [CheckResult], failed: [String]
                var routedTo: [String], invalidated: [String], escalated: Bool, runnable: [String]
            }
            print(try encodeJSON(Outcome(node: outcome.node, slice: slice, advanced: outcome.advanced,
                sliceCompleted: sliceCompleted, produced: outcome.advanced ? outcome.produced : [],
                checks: outcome.results, failed: outcome.blocking.map(\.check),
                routedTo: outcome.routedTo, invalidated: outcome.invalidated, escalated: outcome.escalated,
                runnable: runnable)))
            return
        }
        guard outcome.advanced else {
            print("✗ \(label) failed \(outcome.blocking.count) gate(s)")
            for r in outcome.blocking {
                print("  · \(r.check)\(r.exitCode.map { " (exit \($0))" } ?? "")")
                if let out = r.output, !out.isEmpty {
                    print(out.split(separator: "\n").map { "      \($0)" }.joined(separator: "\n"))
                }
            }
            if outcome.escalated {
                // Bound spent (or nowhere to route): the loop can't resolve itself — a human decides.
                print("⚠ escalated to a human — the gate kept failing past \(Rework.maxRounds) rework round(s)")
                print("  the run is parked at \(label); resolve it or override, then continue")
            } else if !outcome.routedTo.isEmpty {
                // §9: a verdict rejected → rework routes to the producers of the indicted inputs.
                let producers = outcome.routedTo.joined(separator: ", ")
                print("↩ rejected → rework routed to \(producers) (re-runs with the failure as context)")
                print("  invalidated: \(outcome.invalidated.sorted().joined(separator: ", "))")
                print("→ factory next \(runId)  (re-renders \(producers))")
            } else {
                print("→ rework: factory next \(runId)  (re-renders \(label) with the failures as context)")
            }
            return
        }
        print("✓ \(label) accepted — produced \(outcome.produced.isEmpty ? "(nothing)" : outcome.produced.joined(separator: ", "))")
        for r in outcome.results where r.status == .deferred { print("  · deferred: \(r.check)") }
        if sliceCompleted { print("✓ slice '\(slice!)' complete") }

        if Scheduler.isComplete(topState, topPipeline) {
            print("✓ done — all nodes complete")
        } else if let slice, !sliceCompleted {
            print("→ slice '\(slice)' continues  ·  factory next \(runId)")
        } else {
            print("→ runnable: \(runnable.isEmpty ? "—" : runnable.joined(separator: ", "))  ·  factory next \(runId)")
        }
    }
}
