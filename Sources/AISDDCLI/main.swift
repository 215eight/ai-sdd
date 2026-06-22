import Foundation
import ArgumentParser
import AISDDModels
import AISDDEngine

// The `ai-sdd` CLI: the deterministic engine an agent drives interactively. The engine plans
// (what's runnable, what gates pass) and advances state; the agent does the work via skills.
// Commands so far: validate / start / status. `next` and `submit` follow.
@main
struct AISDD: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ai-sdd",
        abstract: "Spec-driven software factory engine (deterministic planner; agents do the work via skills).",
        version: "ai-sdd 0.2.0",
        subcommands: [Guide.self, Validate.self, Start.self, Status.self, Next.self, Submit.self, Check.self, Scope.self, Cover.self, Graph.self, Plan.self, Surface.self, DriftCommand.self]
    )
}

// MARK: - Shared helpers

/// The local run store under the current directory (`.ai-sdd/runs`).
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
/// `.ai-sdd/artifacts/<schema>.<ext>`. Returns the first verdict artifact's hint, else nil.
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

// MARK: - guide

struct Guide: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print the built-in getting-started guide (install → bootstrap → plan → run; travels with the binary)."
    )

    func run() {
        print("""
        ai-sdd — getting started

        The loop: `ai-sdd next` renders the next worker (role + its skill + inputs + gates); your agent
        does that work via the skill; `ai-sdd submit` runs the gates and advances — or routes to rework.
        Repeat until done. The engine is provider-neutral: any agent drives it over a shell.

        1. INSTALL (one-time) — build the binary and put it on your PATH (no Swift needed afterward):
             swift build -c release
             cp .build/release/ai-sdd /usr/local/bin/ai-sdd      # or any dir on your PATH
             ai-sdd --version
           Run ai-sdd from your repo root — compiled gates invoke `ai-sdd check`/`ai-sdd scope`.

        2. SEED THE SKILLS — `ai-sdd-bootstrap` is itself a skill, so it can't install itself. COPY the
           framework skills INTO the repo so it's self-contained (only whoever sets up needs the clone;
           everyone else just clones the target repo + installs the binary):
             AISDD=/path/to/ai-sdd ; TARGET=/path/to/your-repo
             mkdir -p "$TARGET/.ai-sdd/skills" "$TARGET/.agents/skills" "$TARGET/.claude/skills"
             for s in ai-sdd-bootstrap ai-sdd-plan ai-sdd-plan-program ai-sdd-compile-schema ai-sdd-run; do
               cp -R "$AISDD/skills/$s" "$TARGET/.ai-sdd/skills/$s"            # vendor INTO the repo
               ln -sfn "../../.ai-sdd/skills/$s" "$TARGET/.agents/skills/$s"   # Codex → in-repo
               ln -sfn "../../.ai-sdd/skills/$s" "$TARGET/.claude/skills/$s"   # Claude Code → in-repo
             done

        3. BOOTSTRAP the repo's factory (from your repo): ask your agent to run /ai-sdd-bootstrap.
           It discovers your stack, scaffolds .ai-sdd/, compiles the gates, and validates.

        4. A FEATURE:
             /ai-sdd-plan "<brief>"
             ai-sdd start .ai-sdd/features/<slug> --id <slug> && /ai-sdd-run <slug>

        5. A PROGRAM (multiple features + milestones + owners):
             /ai-sdd-plan-program "<program brief>"
             ai-sdd start .ai-sdd/programs/<slug> --id <slug> && /ai-sdd-run <slug>

        MILESTONES — a validation node that gates downstream work: manual (workerKind: human, a person
        records the verdict) or automated (a deterministic check, e.g. `docker compose up …`, gated on
        exit code). Declare them in a feature brief's `## Milestones` section, or as nodes in a program
        graph. A failed milestone blocks downstream until re-validated.

        COMMANDS: guide · validate · start · next · submit · status · check · scope · cover · graph
        Run `ai-sdd <command> --help` for any one. Full adopter docs: QUICKSTART.md in the ai-sdd repo.
        """)
    }
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
        print("→ ai-sdd status \(runId)")
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
            throw ValidationError("no run '\(runId)' (looked in .ai-sdd/runs)")
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
        // which would slip new files past the gate). Ignored files (e.g. `.ai-sdd/`) stay omitted.
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

// MARK: - graph

struct Graph: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Render a Pipeline as a Mermaid dependency graph (Markdown) — the 1:1 DAG view (ADR-0027)."
    )
    @Argument(help: "A pipeline dir (feature graph / build pattern), or a repo factory dir with --project.")
    var dir: String?
    @Option(name: .long, help: "Aggregate a multi-repo program from a plant.yaml — grouped by milestone (ADR-0027).")
    var plant: String?
    @Option(name: .long, help: "Write the Markdown here instead of stdout (parent dirs created).")
    var out: String?
    @Option(name: .long, help: "Mermaid flow direction: TD (top-down) or LR (left-right).")
    var direction: String = "TD"
    @Flag(name: .long, help: "Treat <dir> as a repo factory: index the build pattern + every feature.")
    var project = false
    @Flag(name: .long, help: "Wrap the output in a self-contained HTML page (renders Mermaid in a browser).")
    var html = false
    @Flag(name: .long, help: "Render a self-contained project status dashboard.")
    var dashboard = false

    func run() throws {
        var doc: String
        if dashboard {
            doc = try dashboardDoc()
        } else if let plant {
            doc = try plantDoc(plant)
        } else if let dir {
            doc = project ? try projectDoc(dir) : try singleDoc(dir)
        } else {
            throw ValidationError("pass a pipeline dir (optionally --project), or --plant <plant.yaml>")
        }
        if html {
            let title = doc.split(separator: "\n").first
                .map { String($0.drop { $0 == "#" || $0 == " " }) } ?? "ai-sdd graph"
            doc = GraphRenderer.htmlPage(title: title, markdown: doc)
        }
        if let out {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: out).deletingLastPathComponent(), withIntermediateDirectories: true)
            try doc.write(toFile: out, atomically: true, encoding: .utf8)
            print("✓ wrote \(out)")
        } else {
            print(doc)
        }
    }

    private func dashboardDoc() throws -> String {
        guard !html else {
            throw ValidationError("--dashboard cannot be combined with --html; dashboard mode already renders self-contained HTML")
        }
        guard plant == nil else {
            throw ValidationError("--plant --dashboard is not supported; dashboard mode requires --project over a factory directory")
        }
        guard project else {
            throw ValidationError("--dashboard requires --project")
        }
        guard let dir else {
            throw ValidationError("pass a repo factory dir with --project --dashboard")
        }

        let dashboard = try ProjectDashboardAssembler.assemble(
            factoryDir: URL(fileURLWithPath: dir, isDirectory: true),
            runStore: runStore())
        return GraphRenderer.dashboardPage(title: dashboard.title, sections: dashboard.sections)
    }

    /// One pipeline → one graph (a feature graph or the build pattern). Decode-only — a graph
    /// renders the topology regardless of whether the gates are wired (validation is `ai-sdd validate`).
    private func singleDoc(_ dir: String) throws -> String {
        let env = try SpecLoader().loadPipeline(atDirectory: URL(fileURLWithPath: dir, isDirectory: true))
        let header = GraphRenderer.fragmentHeader(env.metadata).map { "\($0)\n\n" } ?? ""
        return "# \(env.metadata.name) — dependency graph\n\n"
            + "_Generated by `ai-sdd graph` from the pipeline spec (ADR-0027). Renders in any Markdown viewer._\n\n"
            + header
            + GraphRenderer.mermaid(env.spec, direction: direction, inheritedOwner: env.metadata.owner ?? []) + "\n"
    }

    /// Multi-repo program: load each fragment a `plant.yaml` references (by local path, resolved
    /// against the plant file), group by `correlation` (milestone), and render the program index. A
    /// fragment that fails to load renders as a note.
    private func plantDoc(_ plantPath: String) throws -> String {
        let plantURL = URL(fileURLWithPath: plantPath)
        let env = try SpecLoader().loadPlantYAML(String(contentsOf: plantURL, encoding: .utf8))
        let baseDir = plantURL.deletingLastPathComponent()
        let loader = SpecLoader()

        // Group fragment sections by milestone, preserving plant declaration order within each;
        // collect each fragment's metadata for the cross-repo contract overlay.
        var order: [String] = []
        var byMilestone: [String: [GraphRenderer.Section]] = [:]
        var metas: [(name: String, metadata: SpecMetadata)] = []
        for ref in env.spec.fragments {
            guard let path = ref.path else { continue }
            let fragmentURL = URL(fileURLWithPath: path, relativeTo: baseDir)
            let (milestone, section, meta) = fragmentSection(at: fragmentURL, declaredPath: path, loader: loader)
            if byMilestone[milestone] == nil { order.append(milestone) }
            byMilestone[milestone, default: []].append(section)
            if let meta { metas.append((meta.name, meta)) }
        }
        guard !order.isEmpty else {
            throw ValidationError("plant '\(plantPath)' references no fragments (need `fragments: [{ path: … }]`)")
        }
        let milestones = order.sorted().map { GraphRenderer.Milestone(name: $0, fragments: byMilestone[$0] ?? []) }
        var doc = GraphRenderer.programIndex(title: env.metadata.name, milestones: milestones)
        if let contracts = GraphRenderer.contractsSection(Contracts.statuses(metas)) { doc += "\n" + contracts + "\n" }
        return doc + "\n"
    }

    /// Load one fragment and turn it into a (milestone, section, metadata) — its lane/owner in the
    /// heading, its header + graph in the body. Falls back to a note + the "(no milestone)" group on
    /// failure (metadata nil), so one bad fragment doesn't sink the program.
    private func fragmentSection(at url: URL, declaredPath: String, loader: SpecLoader)
        -> (milestone: String, section: GraphRenderer.Section, metadata: SpecMetadata?) {
        guard let env = try? loader.loadPipeline(atDirectory: url) else {
            return ("(no milestone)", .init(heading: declaredPath,
                body: "> ⚠ could not load `\(declaredPath)/pipeline.yaml` — see `ai-sdd validate \(declaredPath)`."), nil)
        }
        let meta = env.metadata
        var heading = meta.name
        if let factory = meta.factory { heading += " · \(factory)" }
        if let owner = meta.owner, !owner.isEmpty { heading += " · @\(owner.joined(separator: ","))" }
        let header = GraphRenderer.fragmentHeader(meta).map { "\($0)\n\n" } ?? ""
        let body = header + GraphRenderer.mermaid(env.spec, direction: direction, inheritedOwner: meta.owner ?? [])
        return (meta.correlation ?? "(no milestone)", .init(heading: heading, body: body), meta)
    }

    /// A repo factory → one index: the build pattern (`<dir>/pipeline.yaml`) + each feature under
    /// `<dir>/features/*`. A feature that fails to load renders as a note, so one bad graph doesn't
    /// sink the index.
    private func projectDoc(_ dir: String) throws -> String {
        var sections: [GraphRenderer.Section] = []
        var title = URL(fileURLWithPath: dir, isDirectory: true).standardizedFileURL.lastPathComponent
        let loader = SpecLoader()

        let homeURL = URL(fileURLWithPath: dir, isDirectory: true)
        if let env = try? loader.loadPipeline(atDirectory: homeURL) {
            title = env.metadata.name
            sections.append(.init(heading: "Build pattern · \(env.metadata.name)",
                                  body: GraphRenderer.mermaid(env.spec, direction: direction)))
        }

        let featuresDir = homeURL.appendingPathComponent("features", isDirectory: true)
        let entries = ((try? FileManager.default.contentsOfDirectory(
            at: featuresDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for entry in entries {
            let name = entry.lastPathComponent
            if let env = try? loader.loadPipeline(atDirectory: entry) {
                let header = GraphRenderer.fragmentHeader(env.metadata).map { "\($0)\n\n" } ?? ""
                sections.append(.init(heading: "Feature · \(name)",
                                      body: header + GraphRenderer.mermaid(
                                        env.spec, direction: direction, inheritedOwner: env.metadata.owner ?? [])))
            } else {
                sections.append(.init(heading: "Feature · \(name)",
                                      body: "> ⚠ could not load `\(name)/pipeline.yaml` — see `ai-sdd validate \(entry.path)`."))
            }
        }

        guard !sections.isEmpty else {
            throw ValidationError("no graphs at '\(dir)' — expected a pipeline.yaml and/or a features/ folder")
        }
        return GraphRenderer.projectIndex(title: title, sections: sections) + "\n"
    }
}

// MARK: - plan

struct Plan: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show the blast radius of pending .ai-sdd/ changes by tier, and whether an ack is required (ADR-0030)."
    )
    @Argument(help: "Directory containing pipeline.yaml and a workers/ folder (the .ai-sdd dir).")
    var dir: String
    @Option(name: .long, help: "Baseline git ref to diff against (default: HEAD).")
    var since: String = "HEAD"
    @Option(name: .long, help: "Tier threshold that requires an ack: refresh | local | contract (default: contract).")
    var requireAck: String = "contract"
    @Option(name: .long, parsing: .upToNextOption,
            help: "Path of a frozen (locked) change to unlock for THIS invocation only — downgrades it to its base tier so it no longer forces exit 3. Repeatable. Never edits .ai-sdd/locks.yaml. A path that matches no frozen change is a no-op with a warning.")
    var unlock: [String] = []

    func run() throws {
        // Validate-first (D3): on an invalid graph this throws ExitCode.failure (1) and we never
        // classify. Distinct from this command's own ExitCode(2)/ExitCode(3) signals.
        _ = try loadValidated(dir)

        let threshold = try Plan.parseTier(requireAck)
        let home = URL(fileURLWithPath: dir, isDirectory: true)
        let changes = ArtifactDiff(workingDirectory: workspace()).changedArtifacts(baseline: since)
        let plan = ChangePlan(changes: changes, homeDirectory: home)

        // Apply any --unlock paths to the classified plan (locks.yaml is never read-for-mutation or
        // written). An unlock that matches no frozen change warns to stderr and continues (L3).
        let downgrade = PlanReport.downgradingUnlocked(
            plan: plan, changes: changes, homeDirectory: home, unlock: unlock)
        for path in downgrade.unmatched {
            FileHandle.standardError.write(Data("⚠ --unlock \(path): no frozen change matches\n".utf8))
        }

        let report = PlanReport.make(classifications: downgrade.classifications, requireAck: threshold)
        print(report.renderedText)

        // Frozen precedence (ADR-0031): a locked change hard-blocks at exit 3, evaluated BEFORE the
        // ack check so it cannot be waved through by lowering --require-ack.
        if report.frozenPresent { throw ExitCode(3) }
        if report.ackRequired { throw ExitCode(2) }
    }

    /// Parse a `--require-ack` value into a `Tier`, failing with a usage error naming the valid tiers.
    static func parseTier(_ raw: String) throws -> Tier {
        switch raw {
        case "refresh":  return .refresh
        case "local":    return .local
        case "contract": return .contract
        default:
            throw ValidationError("unknown --require-ack tier '\(raw)' — expected one of: refresh, local, contract")
        }
    }
}

// MARK: - surface

struct Surface: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Surface framework skills into each coding agent's native skill dir (idempotent symlinks)."
    )
    @Argument(help: "Repo root (its factory home is <dir>/.ai-sdd). Default: current directory.")
    var dir: String = "."
    @Flag(name: .long, help: "Report what would change but apply nothing; exit 1 if out of sync.")
    var check = false

    func run() throws {
        let repoRoot = URL(fileURLWithPath: dir, isDirectory: true)
        let result = try SkillSurface.reconcile(repoRoot: repoRoot, check: check)

        // Report grouped by agent dir, in the agent table's declared order.
        for (_, agentDir) in SkillSurface.agentDirsInOrder(result.ops) {
            let ops = result.ops(forAgentDir: agentDir).sorted { $0.name < $1.name }
            print("\(agentDir):")
            if ops.isEmpty { print("  —"); continue }
            for op in ops {
                let verb = check && op.mutates ? "would \(op.op.rawValue)" : op.op.rawValue
                print("  \(SkillSurface.glyph(op.op)) \(op.name) — \(verb)")
            }
        }

        if check {
            if result.reconciled {
                print("✓ surfaces reconciled — nothing to do")
            } else {
                let changes = result.ops.filter(\.mutates).count
                print("✗ \(changes) surface link(s) out of sync — run `ai-sdd surface` to reconcile")
                throw ExitCode.failure
            }
        } else {
            let changes = result.ops.filter(\.mutates).count
            print(changes == 0
                ? "✓ surfaces already reconciled"
                : "✓ reconciled \(changes) surface link(s)")
        }
    }
}

// MARK: - drift

/// `ai-sdd drift [<dir>]` — a read-only detector for the deterministic drift kinds of ADR-0033
/// (Kinds 1+2; Kind 3 convention-citation is the next slice). It loads the factory home's schemas,
/// committed structural checks, fixed fixtures and provenance, calls the pure `Drift` engine, and
/// prints findings grouped by kind with each finding's remedy. Advisory exit (Dr2): `0` when clean,
/// `1` when findings exist — never blocks a run; it writes nothing.
struct DriftCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "drift",
        abstract: "Detect deterministic drift in <dir> (stale structural gates + fixture↔schema violations); read-only, advisory exit."
    )
    @Argument(help: "Repo root whose factory home is <dir>/.ai-sdd. Default: current directory.")
    var dir: String = "."

    /// The FIXED fixture↔schema map (D-KIND2-FIXTURES): the positive committed example artifacts under
    /// `docs/examples/schema/`, each paired with the schema beside it. Only fixtures meant to VALIDATE
    /// are listed — `*-reject`/`*-bad` are deliberate negative examples (a reject artifact failing its
    /// schema is the verdict gate working, not drift), so they are excluded to keep a reconciled repo
    /// clean. Paths are repo-relative; the command reads them under `dir`.
    static let fixtureMap: [(fixture: String, schema: String)] = [
        ("docs/examples/schema/changeset-good.yaml", "docs/examples/schema/changeset.schema.yaml"),
        ("docs/examples/schema/plan-good.yaml", "docs/examples/schema/feature-plan.schema.yaml"),
        ("docs/examples/schema/review-approve.yaml", "docs/examples/schema/review.schema.yaml")
    ]

    func run() throws {
        let repoRoot = URL(fileURLWithPath: dir, isDirectory: true)
        let home = repoRoot.appendingPathComponent(".ai-sdd", isDirectory: true)
        let loader = SpecLoader()
        let fm = FileManager.default

        // Provenance for the `hand-edited` annotation (ADR-0032). Absent manifest ⇒ empty ⇒ no
        // annotations (purely additive). The engine stays pure: the CLI resolves the hand-edited set.
        let provenance = try Provenance.load(from: home.appendingPathComponent("provenance.json"))
        var handEditedPaths: Set<String> = []
        func noteHandEdited(_ repoRelPath: String) {
            let url = repoRoot.appendingPathComponent(repoRelPath)
            if provenance.status(of: repoRelPath, artifactURL: url) == .handEdited {
                handEditedPaths.insert(repoRelPath)
            }
        }

        // Kind 1 inputs: every schema, and every committed structural check (parsed).
        let schemasDir = home.appendingPathComponent("schemas", isDirectory: true)
        var schemas: [Drift.SchemaInput] = []
        for file in (try? fm.contentsOfDirectory(at: schemasDir, includingPropertiesForKeys: nil)) ?? []
        where file.lastPathComponent.hasSuffix(".schema.yaml") {
            let env = try loader.loadSchemaYAML(try String(contentsOf: file, encoding: .utf8))
            schemas.append(.init(name: env.metadata.name,
                                 version: env.metadata.version ?? 1,
                                 format: env.spec.format ?? "yaml"))
        }

        let checksDir = home.appendingPathComponent("checks", isDirectory: true)
        var committed: [Drift.CommittedCheck] = []
        for file in (try? fm.contentsOfDirectory(at: checksDir, includingPropertiesForKeys: nil)) ?? []
        where file.lastPathComponent.hasSuffix(".structure.check.yaml") {
            let env = try loader.loadCheckYAML(try String(contentsOf: file, encoding: .utf8))
            committed.append(.init(checkName: env.metadata.name, spec: env.spec))
            noteHandEdited(".ai-sdd/checks/\(file.lastPathComponent)")
        }

        // Kind 2 inputs: the fixed fixture↔schema map. A fixture (or its schema) that is missing on
        // disk is simply skipped — drift reports what it can read.
        var fixtures: [Drift.FixtureInput] = []
        for pair in DriftCommand.fixtureMap {
            let fixtureURL = repoRoot.appendingPathComponent(pair.fixture)
            let schemaURL = repoRoot.appendingPathComponent(pair.schema)
            guard let fixtureText = try? String(contentsOf: fixtureURL, encoding: .utf8),
                  let schemaText = try? String(contentsOf: schemaURL, encoding: .utf8) else { continue }
            let schemaEnv = try loader.loadSchemaYAML(schemaText)
            fixtures.append(.init(path: pair.fixture, contents: fixtureText, schema: schemaEnv.spec))
            noteHandEdited(pair.fixture)
        }

        let findings = try Drift.scan(
            schemas: schemas, committedChecks: committed,
            fixtures: fixtures, handEditedPaths: handEditedPaths)

        guard !findings.isEmpty else {
            print("✓ no drift — \(schemas.count) schema(s) reconciled, \(fixtures.count) fixture(s) valid")
            return
        }

        // Grouped by kind, in declared kind order; each finding names its remedy + annotation.
        for kind in DriftKind.allCases {
            let group = findings.filter { $0.kind == kind }
            guard !group.isEmpty else { continue }
            print("\(kind.rawValue) (\(group.count)):")
            for finding in group {
                let annotation = finding.handEdited ? " [hand-edited]" : ""
                print("  ✗ \(finding.subject)\(annotation) — \(finding.detail)")
                print("    → remedy: \(finding.remedy)")
            }
        }
        print("\(findings.count) drift finding(s)")
        throw ExitCode.failure
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
            throw ValidationError("no run '\(runId)' (looked in .ai-sdd/runs)")
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

        try dispense(store: store, dir: meta.pipelineDir, node: pickNode,
                     workers: workers, state: state, pathIds: [], stack: nil, scope: { $0 })
    }

    /// Descend from a runnable node to its leaf Worker, dispensing it. A node that is itself a
    /// slice (kind: pipeline) is marked in progress, then we recurse into its sub-pipeline,
    /// composing `scope` so the leaf's events nest under every ancestor slice. Works to arbitrary
    /// depth (program → feature → slice → worker) — the self-similar model made executable (ADR-0028).
    private func dispense(store: RunStore, dir: String, node: PipelineNode,
                          workers: [String: WorkerSpec], state: RunState,
                          pathIds: [String], stack: String?,
                          scope: (RunEvent) -> RunEvent) throws {
        guard isSlice(node) else {
            try dispenseWorker(store: store, node: node,
                               worker: node.worker.flatMap { workers[$0] } ?? WorkerSpec(),
                               state: state, path: pathIds, stack: stack, scope: scope)
            return
        }
        if !state.inProgressNodes.contains(node.id) {
            try store.append(scope(.nodeStarted(node: node.id)), to: runId)
        }
        let subDir = sliceDir(orchestrationDir: dir, node: node)
        let (subEnv, subWorkers, _) = try loadValidated(subDir)
        let subState = state.slices[node.id] ?? RunState()
        guard let subPick = Scheduler.pick(subState, subEnv.spec),
              let subNode = subEnv.spec.nodes.first(where: { $0.id == subPick }) else {
            try emitIdle(state: subState, pipeline: subEnv.spec)
            return
        }
        try dispense(store: store, dir: subDir, node: subNode,
                     workers: subWorkers, state: subState,
                     pathIds: pathIds + [node.id], stack: node.stack ?? stack,
                     scope: { scope(.scoped(slice: node.id, event: $0)) })
    }

    /// Render a Worker node and mark it in progress. Idempotent — re-running `next` before
    /// `submit` re-renders the same node and appends no duplicate event. `path` is the chain of
    /// ancestor slice ids (empty at the top level); the innermost is the worker's direct slice.
    private func dispenseWorker(store: RunStore, node: PipelineNode, worker: WorkerSpec,
                                state: RunState, path: [String], stack: String?,
                                scope: (RunEvent) -> RunEvent) throws {
        if !state.inProgressNodes.contains(node.id) {
            try store.append(scope(.nodeStarted(node: node.id)), to: runId)
        }
        var instruction = Renderer.instruction(node: node, worker: worker, state: state,
                                               slice: path.last, stack: stack, scopePath: path)
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
            throw ValidationError("no run '\(runId)' (looked in .ai-sdd/runs)")
        }
        let meta = try store.meta(of: runId)
        let (env, workers, checks) = try loadValidated(meta.pipelineDir)
        let pipeline = env.spec
        let state = try store.state(of: runId)

        // Resolve the in-progress top-level node `next` dispensed.
        guard !state.inProgressNodes.isEmpty else {
            throw ValidationError("no node in progress — run `ai-sdd next \(runId)` first")
        }
        let topTarget = try resolve(node, among: state.inProgressNodes, level: "")
        let topNode = pipeline.nodes.first { $0.id == topTarget }!

        let result = try submitDescend(store: store, dir: meta.pipelineDir, node: topNode,
                                       workers: workers, checks: checks, pipeline: pipeline,
                                       state: state, pathIds: [], stack: nil, scope: { $0 })
        try report(outcome: result.outcome, path: result.path, completedSlices: result.completed,
                   topPipeline: pipeline, topState: try store.state(of: runId))
    }

    /// Walk to the in-progress leaf Worker through any nesting, advance it, then on the unwind
    /// propagate completion: each ancestor slice whose sub-pipeline is now complete is itself
    /// completed — at *its parent's* scope — cascading up to the program root so dependents at
    /// every level unlock (ADR-0028). Returns the leaf outcome, the leaf's ancestor path, and the
    /// slice ids that completed (innermost first).
    private func submitDescend(store: RunStore, dir: String, node: PipelineNode,
                               workers: [String: WorkerSpec], checks: [String: CheckSpec],
                               pipeline: PipelineSpec, state: RunState,
                               pathIds: [String], stack: String?,
                               scope: (RunEvent) -> RunEvent)
        throws -> (outcome: AdvanceOutcome, path: [String], completed: [String]) {
        guard isSlice(node) else {
            // Look up the worker by its name (node.worker), not the node id — they differ whenever a
            // node reuses a worker (e.g. a milestone node `m1` running the `milestone-gate` worker).
            let worker = node.worker.flatMap { workers[$0] } ?? WorkerSpec()
            let outcome = try advance(node: node.id, worker: worker,
                                      checks: checks, producedOverride: produced,
                                      pipeline: pipeline, workers: workers, state: state,
                                      store: store, runId: runId, scope: scope)
            return (outcome, pathIds, [])
        }
        let subDir = sliceDir(orchestrationDir: dir, node: node)
        let (subEnv, subWorkers, subChecks) = try loadValidated(subDir)
        let subState = state.slices[node.id] ?? RunState()
        guard !subState.inProgressNodes.isEmpty else {
            throw ValidationError("slice '\(node.id)': no node in progress — run `ai-sdd next \(runId)`")
        }
        // Exactly one node is in progress per active level (`next` dispenses a single leaf path).
        let subTarget = try resolve(nil, among: subState.inProgressNodes, level: "slice '\(node.id)': ")
        let subNode = subEnv.spec.nodes.first { $0.id == subTarget }!

        var result = try submitDescend(store: store, dir: subDir, node: subNode,
                                       workers: subWorkers, checks: subChecks,
                                       pipeline: subEnv.spec, state: subState,
                                       pathIds: pathIds + [node.id], stack: node.stack ?? stack,
                                       scope: { scope(.scoped(slice: node.id, event: $0)) })

        // Unwind: re-read state, descend to this slice's freshly-folded sub-state, and if its
        // whole sub-pipeline is complete, complete this slice node at our parent's scope.
        let afterSub = (try store.state(of: runId)).slice(at: pathIds + [node.id]) ?? RunState()
        if result.outcome.advanced && Scheduler.isComplete(afterSub, subEnv.spec) {
            try store.append(scope(.nodeCompleted(node: node.id, producedArtifacts: [])), to: runId)
            result.completed.append(node.id)
        }
        return (result.outcome, result.path, result.completed)
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

    private func report(outcome: AdvanceOutcome, path: [String], completedSlices: [String],
                        topPipeline: PipelineSpec, topState: RunState) throws {
        let label = (path + [outcome.node]).joined(separator: "/")
        let runnable = Scheduler.runnable(topState, topPipeline)
        if json {
            struct Outcome: Encodable {
                var node: String, path: [String], advanced: Bool, completedSlices: [String]
                var produced: [String], checks: [CheckResult], failed: [String]
                var routedTo: [String], invalidated: [String], escalated: Bool, runnable: [String]
            }
            print(try encodeJSON(Outcome(node: outcome.node, path: path, advanced: outcome.advanced,
                completedSlices: completedSlices, produced: outcome.advanced ? outcome.produced : [],
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
                print("→ ai-sdd next \(runId)  (re-renders \(producers))")
            } else {
                print("→ rework: ai-sdd next \(runId)  (re-renders \(label) with the failures as context)")
            }
            return
        }
        print("✓ \(label) accepted — produced \(outcome.produced.isEmpty ? "(nothing)" : outcome.produced.joined(separator: ", "))")
        for r in outcome.results where r.status == .deferred { print("  · deferred: \(r.check)") }
        for sliceId in completedSlices { print("✓ slice '\(sliceId)' complete") }

        if Scheduler.isComplete(topState, topPipeline) {
            print("✓ done — all nodes complete")
        } else if let inner = path.last, completedSlices.isEmpty {
            print("→ slice '\(inner)' continues  ·  ai-sdd next \(runId)")
        } else {
            print("→ runnable: \(runnable.isEmpty ? "—" : runnable.joined(separator: ", "))  ·  ai-sdd next \(runId)")
        }
    }
}

private extension RunState {
    /// Walk into nested slice sub-state along a path of slice ids (empty path → self).
    func slice(at path: [String]) -> RunState? {
        var current: RunState? = self
        for id in path { current = current?.slices[id] }
        return current
    }
}
