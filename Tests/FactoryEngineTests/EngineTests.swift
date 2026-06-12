import Testing
import Foundation
import FactoryModels
@testable import FactoryEngine

struct EngineTests {
    let loader = SpecLoader()

    // A small diamond DAG:  architect ──plan.v1──▶ {migrate, config};  migrate ──sql-migration.v1──▶ api
    let pipelineJSON = """
    {
      "apiVersion": "factory/v1", "kind": "Pipeline",
      "metadata": { "name": "demo", "version": 1 },
      "spec": {
        "semantics": "enabler",
        "nodes": [
          { "id": "architect", "worker": "architect" },
          { "id": "migrate",   "worker": "migrate" },
          { "id": "config",    "worker": "config" },
          { "id": "api",       "worker": "api" }
        ],
        "edges": [
          { "from": "architect", "to": "migrate", "artifact": "plan.v1" },
          { "from": "architect", "to": "config",  "artifact": "plan.v1" },
          { "from": "migrate",   "to": "api",     "artifact": "sql-migration.v1" }
        ]
      }
    }
    """

    let workerJSON: [String] = [
        #"{ "apiVersion":"factory/v1","kind":"Worker","metadata":{"name":"architect"},"spec":{"workerKind":"transform","produces":[{"schema":"plan.v1"}]}}"#,
        #"{ "apiVersion":"factory/v1","kind":"Worker","metadata":{"name":"migrate"},"spec":{"workerKind":"transform","consumes":[{"schema":"plan.v1","required":true}],"produces":[{"schema":"sql-migration.v1"}]}}"#,
        #"{ "apiVersion":"factory/v1","kind":"Worker","metadata":{"name":"config"},"spec":{"workerKind":"transform","consumes":[{"schema":"plan.v1","required":true}],"produces":[{"schema":"config.v1"}]}}"#,
        #"{ "apiVersion":"factory/v1","kind":"Worker","metadata":{"name":"api"},"spec":{"workerKind":"transform","consumes":[{"schema":"sql-migration.v1","required":true}],"produces":[{"schema":"openapi.v1"}]}}"#
    ]

    private func loadWorkers() throws -> [String: WorkerSpec] {
        var workers: [String: WorkerSpec] = [:]
        for json in workerJSON {
            let env = try loader.loadWorker(Data(json.utf8))
            workers[env.metadata.name] = env.spec
        }
        return workers
    }

    private func loadPipeline() throws -> PipelineSpec {
        try loader.loadPipeline(Data(pipelineJSON.utf8)).spec
    }

    // MARK: - Loading & validation

    // Decode the envelope + flow specs, and assert the wiring type-checks cleanly.
    @Test func loadAndValidate() throws {
        let pipeline = try loadPipeline()
        #expect(pipeline.nodes.count == 4)
        #expect(pipeline.edges.count == 3)

        let issues = SpecValidator.validate(pipeline: pipeline, workers: try loadWorkers())
        #expect(issues.isEmpty, "expected a clean pipeline, got: \(issues)")
    }

    // The DAG resolves: readiness advances as nodes complete, with parallel branches.
    @Test func runnableProgression() throws {
        let pipeline = try loadPipeline()
        var state = RunState()

        // architect is the only source.
        #expect(Set(Scheduler.runnable(state, pipeline)) == ["architect"])

        // architect completes → plan.v1 ready → migrate AND config become runnable (parallel).
        state = Reducer.reduce(state, .nodeCompleted(node: "architect", producedArtifacts: ["plan.v1"]))
        #expect(Set(Scheduler.runnable(state, pipeline)) == ["migrate", "config"])

        // migrate completes → sql-migration.v1 ready → api runnable; config still pending.
        state = Reducer.reduce(state, .nodeCompleted(node: "migrate", producedArtifacts: ["sql-migration.v1"]))
        #expect(Set(Scheduler.runnable(state, pipeline)) == ["config", "api"])
    }

    // The reducer is a pure fold: same events ⇒ same state.
    @Test func reducerIsAPureFold() {
        let events: [RunEvent] = [
            .nodeCompleted(node: "architect", producedArtifacts: ["plan.v1"]),
            .nodeCompleted(node: "migrate", producedArtifacts: ["sql-migration.v1"])
        ]
        let a = Reducer.reduce(RunState(), events: events)
        let b = Reducer.reduce(RunState(), events: events)
        #expect(a == b)
        #expect(a.completedNodes == ["architect", "migrate"])
        #expect(a.readyArtifacts == ["plan.v1", "sql-migration.v1"])
    }

    // MARK: - Invalid spec files

    // Malformed YAML (unterminated flow mapping) → SpecLoadError.syntax (decode IS validation, ADR-0020).
    @Test func malformedYAMLThrows() throws {
        let badYAML = "apiVersion: factory/v1\nkind: Pipeline\nmetadata: { name: x"  // missing closing brace
        let error = try #require(throws: SpecLoadError.self) { try loader.loadPipelineYAML(badYAML) }
        #expect(error.isSyntax)
    }

    // A missing required field (metadata.name) → SpecLoadError.schema.
    @Test func missingRequiredFieldThrows() throws {
        let noName = """
        apiVersion: factory/v1
        kind: Worker
        metadata: { version: 1 }
        spec: { workerKind: transform }
        """
        let error = try #require(throws: SpecLoadError.self) { try loader.loadWorkerYAML(noName) }
        #expect(error.isSchema)
    }

    // A port without a `schema` → SpecLoadError.schema.
    @Test func portWithoutSchemaThrows() throws {
        let noSchema = """
        apiVersion: factory/v1
        kind: Worker
        metadata: { name: broken }
        spec: { consumes: [{ required: true }] }
        """
        let error = try #require(throws: SpecLoadError.self) { try loader.loadWorkerYAML(noSchema) }
        #expect(error.isSchema)
    }

    // A mis-wired edge (artifact not produced/consumed by its endpoints) fails validation (§5).
    @Test func edgeTypeMismatchIsCaught() throws {
        let badPipeline = """
        {
          "apiVersion": "factory/v1", "kind": "Pipeline", "metadata": { "name": "bad" },
          "spec": {
            "nodes": [ { "id": "migrate", "worker": "migrate" }, { "id": "api", "worker": "api" } ],
            "edges": [ { "from": "migrate", "to": "api", "artifact": "wrong.v1" } ]
          }
        }
        """
        let pipeline = try loader.loadPipeline(Data(badPipeline.utf8)).spec
        let issues = SpecValidator.validate(pipeline: pipeline, workers: try loadWorkers())
        #expect(issues.contains { $0.kind == .edgeTypeMismatch }, "got: \(issues)")
    }

    // A node referencing a worker that doesn't exist is caught at validation.
    @Test func unknownWorkerIsCaught() throws {
        let pipeline = try loadPipeline()
        var workers = try loadWorkers()
        workers["api"] = nil                       // drop a worker the pipeline still references
        let issues = SpecValidator.validate(pipeline: pipeline, workers: workers)
        #expect(issues.contains { $0.kind == .unknownWorker }, "got: \(issues)")
    }

    // An edge referencing a node that doesn't exist is caught at validation.
    @Test func unknownNodeEdgeIsCaught() throws {
        let badPipeline = """
        {
          "apiVersion": "factory/v1", "kind": "Pipeline", "metadata": { "name": "bad" },
          "spec": {
            "nodes": [ { "id": "architect", "worker": "architect" } ],
            "edges": [ { "from": "architect", "to": "ghost", "artifact": "plan.v1" } ]
          }
        }
        """
        let pipeline = try loader.loadPipeline(Data(badPipeline.utf8)).spec
        let issues = SpecValidator.validate(pipeline: pipeline, workers: try loadWorkers())
        #expect(issues.contains { $0.kind == .unknownNode }, "got: \(issues)")
    }

    // MARK: - next: pick, in-progress state, rendering

    // `pick` is deterministic: the first runnable node in declaration order.
    @Test func pickIsFirstRunnableInOrder() throws {
        let pipeline = try loadPipeline()
        var state = RunState()
        #expect(Scheduler.pick(state, pipeline) == "architect")

        // With migrate AND config runnable, pick takes the first in declaration order (migrate).
        state = Reducer.reduce(state, .nodeCompleted(node: "architect", producedArtifacts: ["plan.v1"]))
        #expect(Set(Scheduler.runnable(state, pipeline)) == ["migrate", "config"])
        #expect(Scheduler.pick(state, pipeline) == "migrate")
    }

    // `pick` prefers an already in-progress node, so re-running `next` re-renders the same work.
    @Test func pickPrefersInProgress() throws {
        let pipeline = try loadPipeline()
        var state = RunState()
        state = Reducer.reduce(state, .nodeCompleted(node: "architect", producedArtifacts: ["plan.v1"]))
        // config (second in order) is in progress → pick re-selects it over migrate (first).
        state = Reducer.reduce(state, .nodeStarted(node: "config"))
        #expect(Scheduler.pick(state, pipeline) == "config")
    }

    // `nodeStarted` marks a node in progress; `nodeCompleted` clears it and records completion.
    @Test func startedThenCompletedTracksInProgress() {
        var state = RunState()
        state = Reducer.reduce(state, .nodeStarted(node: "architect"))
        #expect(state.inProgressNodes == ["architect"])
        #expect(state.completedNodes.isEmpty)

        state = Reducer.reduce(state, .nodeCompleted(node: "architect", producedArtifacts: ["plan.v1"]))
        #expect(state.inProgressNodes.isEmpty)
        #expect(state.completedNodes == ["architect"])
    }

    // The renderer reflects readiness: a runnable node's required inputs show as ready.
    @Test func rendererReflectsReadiness() {
        let node = PipelineNode(id: "coder", worker: "coder")
        let worker = WorkerSpec(
            workerKind: "transform",
            consumes: [PortSpec(schema: "plan.v1", required: true)],
            produces: [PortSpec(schema: "code.v1")],
            task: WorkerTask(skill: "implement-change"),
            checks: ["typecheck", "unit"],
            model: "deep-reasoning", reasoning: "high"
        )
        let state = RunState(readyArtifacts: ["plan.v1"], completedNodes: ["architect"])

        let instruction = Renderer.instruction(node: node, worker: worker, state: state)
        #expect(instruction.node == "coder")
        #expect(instruction.worker == "coder")
        #expect(instruction.task == WorkerTask(skill: "implement-change"))
        #expect(instruction.produces == ["code.v1"])
        #expect(instruction.checks == ["typecheck", "unit"])
        #expect(instruction.consumes == [RenderedInput(schema: "plan.v1", required: true, ready: true)])

        // An input whose Schema is not ready renders as missing.
        let unmet = Renderer.instruction(node: node, worker: worker, state: RunState())
        #expect(unmet.consumes == [RenderedInput(schema: "plan.v1", required: true, ready: false)])
    }

    // The Markdown rendering surfaces the task, inputs, produces, and checks.
    @Test func markdownSurfacesTheKeyFields() {
        let node = PipelineNode(id: "reviewer", worker: "reviewer", required: true)
        let worker = WorkerSpec(
            workerKind: "transform",
            consumes: [PortSpec(schema: "code.v1", required: true)],
            produces: [PortSpec(schema: "review.v1")],
            task: WorkerTask(skill: "review-change"),
            checks: ["judge.review-quality"]
        )
        let md = Renderer.markdown(
            Renderer.instruction(node: node, worker: worker, state: RunState(readyArtifacts: ["code.v1"])))

        #expect(md.contains("Worker `reviewer`"))
        #expect(md.contains("Run skill: `review-change`"))
        #expect(md.contains("`code.v1` — required, ✓ ready"))
        #expect(md.contains("`review.v1`"))
        #expect(md.contains("judge.review-quality"))
        #expect(md.contains("required gate"))
    }

    // A node with no incoming edges renders as a source (no inputs).
    @Test func sourceNodeRendersNoInputs() {
        let node = PipelineNode(id: "architect", worker: "architect")
        let worker = WorkerSpec(workerKind: "transform", produces: [PortSpec(schema: "plan.v1")],
                                task: WorkerTask(skill: "plan-change"))
        let instruction = Renderer.instruction(node: node, worker: worker, state: RunState())
        #expect(instruction.consumes.isEmpty)
        #expect(Renderer.markdown(instruction).contains("(none — this is a source node)"))
    }

    // MARK: - submit: checks, gates, rework

    private func runner(_ outcomes: [String: (Int32, String)]) -> CheckRunner {
        // A CheckRunner whose command execution is stubbed per command string (no shelling out).
        CheckRunner(workingDirectory: URL(fileURLWithPath: "/")) { command, _ in
            outcomes[command] ?? (0, "")
        }
    }

    // A deterministic check passes on exit 0 and fails (blocking) on non-zero; output is kept on failure.
    @Test func deterministicCheckPassAndFail() {
        let specs: [String: CheckSpec] = [
            "ok":  CheckSpec(checkKind: "deterministic", command: "run-ok"),
            "bad": CheckSpec(checkKind: "deterministic", command: "run-bad")
        ]
        let results = runner(["run-ok": (0, ""), "run-bad": (1, "boom")])
            .run(["ok", "bad"], specs: specs)

        #expect(results[0] == CheckResult(check: "ok", status: .passed, required: true, exitCode: 0))
        #expect(results[1].status == .failed)
        #expect(results[1].isBlockingFailure)
        #expect(results[1].output == "boom")
    }

    // judge/human checks are deferred (non-blocking); a non-required failing check does not block.
    @Test func judgeIsDeferredAndOptionalDoesNotBlock() {
        let specs: [String: CheckSpec] = [
            "judge.x": CheckSpec(checkKind: "judge"),
            "soft":    CheckSpec(checkKind: "deterministic", command: "run-soft", required: false)
        ]
        let results = runner(["run-soft": (1, "warned")]).run(["judge.x", "soft"], specs: specs)

        #expect(results[0].status == .deferred)
        #expect(!results[0].isBlockingFailure)
        #expect(results[1].status == .failed)
        #expect(!results[1].isBlockingFailure, "an optional check must not block")
    }

    // A deterministic check missing its command is a misconfiguration → blocking failure, not a pass.
    @Test func deterministicWithoutCommandFails() {
        let specs = ["x": CheckSpec(checkKind: "deterministic")]
        let result = runner([:]).run(["x"], specs: specs)[0]
        #expect(result.status == .failed)
        #expect(result.isBlockingFailure)
    }

    // A failed submit returns the node to runnable carrying its rework context; passing clears it.
    @Test func checkFailedThenCompletedClearsRework() {
        var state = RunState()
        state = Reducer.reduce(state, .nodeStarted(node: "coder"))
        state = Reducer.reduce(state, .checkFailed(node: "coder", checks: ["unit"]))
        #expect(state.inProgressNodes.isEmpty)
        #expect(state.completedNodes.isEmpty)
        #expect(state.failedChecks["coder"] == ["unit"])

        // The node is re-dispensed and this time passes.
        state = Reducer.reduce(state, .nodeStarted(node: "coder"))
        #expect(state.failedChecks["coder"] == ["unit"], "rework context persists across the re-attempt")
        state = Reducer.reduce(state, .nodeCompleted(node: "coder", producedArtifacts: ["code.v1"]))
        #expect(state.failedChecks["coder"] == nil)
        #expect(state.completedNodes == ["coder"])
    }

    // The renderer surfaces a node's rework context (its last failed gates).
    @Test func rendererShowsReworkContext() {
        let node = PipelineNode(id: "coder", worker: "coder")
        let worker = WorkerSpec(consumes: [PortSpec(schema: "plan.v1", required: true)],
                                produces: [PortSpec(schema: "code.v1")], checks: ["unit"])
        let state = RunState(readyArtifacts: ["plan.v1"], failedChecks: ["coder": ["unit"]])

        let instruction = Renderer.instruction(node: node, worker: worker, state: state)
        #expect(instruction.rework == ["unit"])
        let md = Renderer.markdown(instruction)
        #expect(md.contains("## Rework"))
        #expect(md.contains("- unit"))
    }

    // A worker referencing a check that has no spec is caught at validation.
    @Test func unknownCheckIsCaught() throws {
        let pipeline = try loader.loadPipeline(Data("""
        {
          "apiVersion": "factory/v1", "kind": "Pipeline", "metadata": { "name": "c" },
          "spec": { "nodes": [ { "id": "architect", "worker": "architect" } ], "edges": [] }
        }
        """.utf8)).spec
        let workers = ["architect": WorkerSpec(workerKind: "transform",
                                               produces: [PortSpec(schema: "plan.v1")],
                                               checks: ["ghost-check"])]
        let issues = SpecValidator.validate(pipeline: pipeline, workers: workers, checks: [:])
        #expect(issues.contains { $0.kind == .unknownCheck }, "got: \(issues)")

        // With the check declared, it validates clean.
        let withCheck = SpecValidator.validate(pipeline: pipeline, workers: workers,
                                               checks: ["ghost-check": CheckSpec(checkKind: "deterministic", command: "true")])
        #expect(withCheck.isEmpty, "got: \(withCheck)")
    }

    // A Check spec decodes into the strict type.
    @Test func loadsCheckSpec() throws {
        let env = try loader.loadCheck(Data(
            #"{ "apiVersion":"factory/v1","kind":"Check","metadata":{"name":"unit"},"spec":{"checkKind":"deterministic","command":"swift test"}}"#.utf8))
        #expect(env.metadata.name == "unit")
        #expect(env.spec == CheckSpec(checkKind: "deterministic", command: "swift test"))
    }

    // MARK: - Piece 5: orchestration graph + slice descent

    // A pure dependency graph (depends_on edges, no artifacts) schedules by node completion.
    @Test func dependencyGraphSchedulesByCompletion() {
        // foundation ──▶ api ; foundation ──▶ ui   (artifact-less edges)
        let pipeline = PipelineSpec(
            nodes: [PipelineNode(id: "foundation", kind: "pipeline", pipeline: "p"),
                    PipelineNode(id: "api", kind: "pipeline", pipeline: "p"),
                    PipelineNode(id: "ui", kind: "pipeline", pipeline: "p")],
            edges: [PipelineEdge(from: OneOrMany(["foundation"]), to: "api"),
                    PipelineEdge(from: OneOrMany(["foundation"]), to: "ui")])
        var state = RunState()
        #expect(Scheduler.runnable(state, pipeline) == ["foundation"], "only the root is runnable")

        // foundation completing (no artifacts) unlocks both dependents.
        state = Reducer.reduce(state, .nodeCompleted(node: "foundation", producedArtifacts: []))
        #expect(Set(Scheduler.runnable(state, pipeline)) == ["api", "ui"])
        #expect(!Scheduler.isComplete(state, pipeline))
    }

    // A join over [a, b] waits for ALL its sources to complete, even with a wildcard artifact.
    @Test func joinWaitsForAllSources() {
        let pipeline = PipelineSpec(
            nodes: [PipelineNode(id: "a"), PipelineNode(id: "b"), PipelineNode(id: "join", kind: "join")],
            edges: [PipelineEdge(from: OneOrMany(["a", "b"]), to: "join", artifact: "*")])
        var state = RunState()
        #expect(Set(Scheduler.runnable(state, pipeline)) == ["a", "b"], "join not yet runnable")

        state = Reducer.reduce(state, .nodeCompleted(node: "a", producedArtifacts: []))
        #expect(Set(Scheduler.runnable(state, pipeline)) == ["b"], "join still waits on b")
        state = Reducer.reduce(state, .nodeCompleted(node: "b", producedArtifacts: []))
        #expect(Scheduler.runnable(state, pipeline) == ["join"])
    }

    // A dependency cycle is rejected at load.
    @Test func cycleIsCaught() {
        let pipeline = PipelineSpec(
            nodes: [PipelineNode(id: "a", worker: "w"), PipelineNode(id: "b", worker: "w")],
            edges: [PipelineEdge(from: OneOrMany(["a"]), to: "b"),
                    PipelineEdge(from: OneOrMany(["b"]), to: "a")])
        let issues = SpecValidator.validate(pipeline: pipeline, workers: ["w": WorkerSpec()])
        #expect(issues.contains { $0.kind == .cycle }, "got: \(issues)")
    }

    // A slice node (kind: pipeline) with no sub-pipeline reference is rejected.
    @Test func sliceWithoutPipelineRefIsCaught() {
        let pipeline = PipelineSpec(nodes: [PipelineNode(id: "s", kind: "pipeline")], edges: [])
        let issues = SpecValidator.validate(pipeline: pipeline, workers: [:])
        #expect(issues.contains { $0.kind == .missingPipelineRef }, "got: \(issues)")
    }

    // A scoped event folds into that slice's sub-state, leaving the top level untouched.
    @Test func scopedEventsRouteIntoSliceSubState() {
        var state = RunState()
        state = Reducer.reduce(state, .nodeStarted(node: "foundation"))          // top: slice in progress
        state = Reducer.reduce(state, .scoped(slice: "foundation",
                                              event: .nodeCompleted(node: "architect", producedArtifacts: ["plan.v1"])))
        // Top level sees the slice in progress; the sub-state carries the worker's completion.
        #expect(state.inProgressNodes == ["foundation"])
        #expect(state.completedNodes.isEmpty)
        let sub = state.slices["foundation"]
        #expect(sub?.completedNodes == ["architect"])
        #expect(sub?.readyArtifacts == ["plan.v1"])
    }

    // The whole sub-pipeline completing is what `isComplete` detects (the slice-done trigger).
    @Test func subPipelineCompletionIsDetectable() throws {
        let sub = try loader.loadPipeline(Data("""
        {
          "apiVersion": "factory/v1", "kind": "Pipeline", "metadata": { "name": "cy" },
          "spec": { "nodes": [ { "id": "architect", "worker": "a" }, { "id": "coder", "worker": "c" } ],
                    "edges": [ { "from": "architect", "to": "coder", "artifact": "plan.v1" } ] }
        }
        """.utf8)).spec
        var state = RunState()
        state = Reducer.reduce(state, .nodeCompleted(node: "architect", producedArtifacts: ["plan.v1"]))
        #expect(!Scheduler.isComplete(state, sub))
        state = Reducer.reduce(state, .nodeCompleted(node: "coder", producedArtifacts: ["code.v1"]))
        #expect(Scheduler.isComplete(state, sub))
    }

    // A worker rendered inside a slice carries the slice + stack context.
    @Test func rendererCarriesSliceContext() {
        let node = PipelineNode(id: "architect", worker: "architect")
        let worker = WorkerSpec(produces: [PortSpec(schema: "plan.v1")], task: WorkerTask(skill: "plan-change"))
        let instruction = Renderer.instruction(node: node, worker: worker, state: RunState(),
                                               slice: "foundation", stack: "core")
        #expect(instruction.slice == "foundation")
        #expect(instruction.stack == "core")
        let md = Renderer.markdown(instruction)
        #expect(md.contains("slice `foundation`"))
        #expect(md.contains("stack `core`"))
    }

    // MARK: - Run store

    // The store is append-only; state is always a pure projection of the replayed event log.
    @Test func runStorePersistsAndReplays() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("factory-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = RunStore(root: tmp)
        try store.create(runId: "r1", pipelineDir: "/x")
        try store.append(.runStarted(seedArtifacts: []), to: "r1")
        try store.append(.nodeCompleted(node: "architect", producedArtifacts: ["plan.v1"]), to: "r1")
        try store.append(.nodeCompleted(node: "coder", producedArtifacts: ["code.v1"]), to: "r1")

        #expect(store.exists("r1"))
        #expect(try store.meta(of: "r1").pipelineDir == "/x")
        #expect(try store.events(of: "r1").count == 3)
        #expect(try store.runIds() == ["r1"])

        let state = try store.state(of: "r1")
        #expect(state.completedNodes == ["architect", "coder"])
        #expect(state.readyArtifacts == ["plan.v1", "code.v1"])
    }
}

private extension SpecLoadError {
    var isSyntax: Bool { if case .syntax = self { return true } else { return false } }
    var isSchema: Bool { if case .schema = self { return true } else { return false } }
}
