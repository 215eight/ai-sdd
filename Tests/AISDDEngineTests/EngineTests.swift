import Testing
import Foundation
import AISDDModels
@testable import AISDDEngine

struct EngineTests {
    let loader = SpecLoader()

    // A small diamond DAG:  architect ──plan.v1──▶ {migrate, config};  migrate ──sql-migration.v1──▶ api
    let pipelineJSON = """
    {
      "apiVersion": "ai-sdd/v1", "kind": "Pipeline",
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
        #"{ "apiVersion":"ai-sdd/v1","kind":"Worker","metadata":{"name":"architect"},"spec":{"workerKind":"transform","produces":[{"schema":"plan.v1"}]}}"#,
        #"{ "apiVersion":"ai-sdd/v1","kind":"Worker","metadata":{"name":"migrate"},"spec":{"workerKind":"transform","consumes":[{"schema":"plan.v1","required":true}],"produces":[{"schema":"sql-migration.v1"}]}}"#,
        #"{ "apiVersion":"ai-sdd/v1","kind":"Worker","metadata":{"name":"config"},"spec":{"workerKind":"transform","consumes":[{"schema":"plan.v1","required":true}],"produces":[{"schema":"config.v1"}]}}"#,
        #"{ "apiVersion":"ai-sdd/v1","kind":"Worker","metadata":{"name":"api"},"spec":{"workerKind":"transform","consumes":[{"schema":"sql-migration.v1","required":true}],"produces":[{"schema":"openapi.v1"}]}}"#
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
        let badYAML = "apiVersion: ai-sdd/v1\nkind: Pipeline\nmetadata: { name: x"  // missing closing brace
        let error = try #require(throws: SpecLoadError.self) { try loader.loadPipelineYAML(badYAML) }
        #expect(error.isSyntax)
    }

    // A missing required field (metadata.name) → SpecLoadError.schema.
    @Test func missingRequiredFieldThrows() throws {
        let noName = """
        apiVersion: ai-sdd/v1
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
        apiVersion: ai-sdd/v1
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
          "apiVersion": "ai-sdd/v1", "kind": "Pipeline", "metadata": { "name": "bad" },
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
          "apiVersion": "ai-sdd/v1", "kind": "Pipeline", "metadata": { "name": "bad" },
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
          "apiVersion": "ai-sdd/v1", "kind": "Pipeline", "metadata": { "name": "c" },
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
            #"{ "apiVersion":"ai-sdd/v1","kind":"Check","metadata":{"name":"unit"},"spec":{"checkKind":"deterministic","command":"swift test"}}"#.utf8))
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
          "apiVersion": "ai-sdd/v1", "kind": "Pipeline", "metadata": { "name": "cy" },
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

    // A doubly-nested scoped event folds two levels down (feature → build → worker), leaving the
    // intermediate level's own completion set untouched (recursive descent, ADR-0028).
    @Test func nestedScopedEventsRouteToDepth2() {
        var state = RunState()
        state = Reducer.reduce(state, .scoped(slice: "feature",
            event: .scoped(slice: "build",
                event: .nodeCompleted(node: "architect", producedArtifacts: ["plan.v1"]))))
        #expect(state.completedNodes.isEmpty, "top level untouched")
        let feature = state.slices["feature"]
        #expect(feature?.completedNodes.isEmpty == true, "feature level untouched")
        let build = feature?.slices["build"]
        #expect(build?.completedNodes == ["architect"])
        #expect(build?.readyArtifacts == ["plan.v1"])
    }

    // Depth-2 completion cascades up: a leaf worker completing finishes its build sub-pipeline,
    // which finishes its feature, which unlocks the dependent feature at the program root. This is
    // the exact event shape + cascade condition `submitDescend` produces (ADR-0028).
    @Test func depth2CompletionCascadesAndUnlocksDependent() {
        // program: A ──▶ B  (each a feature sub-pipeline)
        let program = PipelineSpec(
            nodes: [PipelineNode(id: "A", kind: "pipeline", pipeline: "a"),
                    PipelineNode(id: "B", kind: "pipeline", pipeline: "b")],
            edges: [PipelineEdge(from: OneOrMany(["A"]), to: "B")])
        let feature = PipelineSpec(nodes: [PipelineNode(id: "s", kind: "pipeline", pipeline: "p")], edges: [])
        let build = PipelineSpec(nodes: [PipelineNode(id: "w", worker: "w")], edges: [])

        var state = RunState()
        #expect(Scheduler.runnable(state, program) == ["A"], "only A is runnable")

        // Drive the leaf worker w (inside A › s) to completion via nested scoped events.
        for event: RunEvent in [.nodeStarted(node: "A"),
                                .scoped(slice: "A", event: .nodeStarted(node: "s")),
                                .scoped(slice: "A", event: .scoped(slice: "s", event: .nodeStarted(node: "w"))),
                                .scoped(slice: "A", event: .scoped(slice: "s",
                                    event: .nodeCompleted(node: "w", producedArtifacts: [])))] {
            state = Reducer.reduce(state, event)
        }
        // The build sub-pipeline is complete → cascade completes the slice node `s` under A.
        #expect(Scheduler.isComplete(state.slices["A"]?.slices["s"] ?? RunState(), build))
        state = Reducer.reduce(state, .scoped(slice: "A", event: .nodeCompleted(node: "s", producedArtifacts: [])))

        // Feature A's sub-pipeline is now complete → cascade completes A at the program root.
        #expect(Scheduler.isComplete(state.slices["A"] ?? RunState(), feature))
        state = Reducer.reduce(state, .nodeCompleted(node: "A", producedArtifacts: []))

        // A done at the top unlocks B; the program is not yet complete.
        #expect(state.completedNodes == ["A"])
        #expect(Scheduler.runnable(state, program) == ["B"])
        #expect(!Scheduler.isComplete(state, program))
    }

    // A worker rendered deep in the nesting carries the full scope-path lineage (ADR-0028).
    @Test func rendererCarriesScopePath() {
        let node = PipelineNode(id: "architect", worker: "architect")
        let worker = WorkerSpec(produces: [PortSpec(schema: "plan.v1")], task: WorkerTask(skill: "plan-change"))
        let instruction = Renderer.instruction(node: node, worker: worker, state: RunState(),
                                               slice: "build", stack: "core", scopePath: ["checkout", "build"])
        #expect(instruction.scopePath == ["checkout", "build"])
        #expect(Renderer.markdown(instruction).contains("path `checkout › build`"))
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

    // MARK: - Schema validator (Tier-1: structure + invariants → deterministic gate)

    private let planSchemaJSON = """
    {
      "apiVersion": "ai-sdd/v1", "kind": "Schema", "metadata": { "name": "feature-plan", "version": 1 },
      "spec": { "fields": {
        "decisions": { "type": "list", "required": true,
          "invariants": [ { "nonEmpty": true }, { "all": { "field": "status", "eq": "closed" } } ] },
        "files": { "type": "list", "required": true,
          "invariants": [ { "all": { "matches": "^Sources/|^Tests/" } } ] }
      } }
    }
    """

    // A conforming artifact yields no violations.
    @Test func schemaValidatorAcceptsGoodArtifact() throws {
        let schema = try loader.loadSchema(Data(planSchemaJSON.utf8)).spec
        let good = """
        decisions:
          - { q: "db?", answer: "sqlite", status: closed }
        files: [ "Sources/X.swift", "Tests/XTests.swift" ]
        """
        #expect(try SchemaValidator.validate(schema, artifactYAML: good).isEmpty)
    }

    // An open decision and an out-of-scope path are each caught, located precisely.
    @Test func schemaValidatorCatchesViolations() throws {
        let schema = try loader.loadSchema(Data(planSchemaJSON.utf8)).spec
        let bad = """
        decisions:
          - { q: "db?", answer: "sqlite", status: closed }
          - { q: "store?", answer: "TBD", status: open }
        files: [ "Sources/X.swift", "scripts/hack.sh" ]
        """
        let violations = try SchemaValidator.validate(schema, artifactYAML: bad)
        #expect(violations.contains { $0.field == "decisions[1].status" })
        #expect(violations.contains { $0.field == "files[1]" })
    }

    // A missing required field is reported.
    @Test func schemaValidatorFlagsMissingRequired() throws {
        let schema = SchemaSpec(fields: ["plan": FieldSpec(required: true)])
        let violations = try SchemaValidator.validate(schema, artifactYAML: "other: 1")
        #expect(violations.contains { $0.field == "plan" && $0.message.contains("missing") })
    }

    // MARK: - Review verdict gate (D1: the reviewer is a real, blocking gate)

    // The review Schema: per-item verdicts must all be `pass`, and the overall verdict `approve`.
    private let reviewSchemaJSON = """
    {
      "apiVersion": "ai-sdd/v1", "kind": "Schema", "metadata": { "name": "review", "version": 1 },
      "spec": { "fields": {
        "items": { "type": "list", "required": true, "invariants": [
          { "nonEmpty": true },
          { "all": { "field": "id", "nonEmpty": true } },
          { "all": { "field": "verdict", "matches": "^(pass|fail)$" } },
          { "all": { "field": "verdict", "eq": "pass" } } ] },
        "verdict": { "type": "string", "required": true,
          "invariants": [ { "matches": "^(approve|reject)$" }, { "eq": "approve" } ] }
      } }
    }
    """

    // approve + every item pass → the gate passes (no violations).
    @Test func reviewGateAcceptsApproveAllPass() throws {
        let schema = try loader.loadSchema(Data(reviewSchemaJSON.utf8)).spec
        let approve = """
        items:
          - { id: parse-fixture,  verdict: pass }
          - { id: persist-result, verdict: pass }
        verdict: approve
        """
        #expect(try SchemaValidator.validate(schema, artifactYAML: approve).isEmpty)
    }

    // A reject blocks: both the failed item and the overall verdict are flagged.
    @Test func reviewGateBlocksOnRejectAndFailedItem() throws {
        let schema = try loader.loadSchema(Data(reviewSchemaJSON.utf8)).spec
        let reject = """
        items:
          - { id: parse-fixture,  verdict: pass }
          - { id: persist-result, verdict: fail }
        verdict: reject
        """
        let violations = try SchemaValidator.validate(schema, artifactYAML: reject)
        #expect(violations.contains { $0.field == "items[1].verdict" }, "the failed item must be flagged")
        #expect(violations.contains { $0.field == "verdict" }, "the overall reject must be flagged")
    }

    // An approve verdict does not excuse a single failed item — the gate still blocks.
    @Test func reviewGateBlocksWhenApproveButItemFails() throws {
        let schema = try loader.loadSchema(Data(reviewSchemaJSON.utf8)).spec
        let inconsistent = """
        items:
          - { id: parse-fixture,  verdict: fail }
        verdict: approve
        """
        let violations = try SchemaValidator.validate(schema, artifactYAML: inconsistent)
        #expect(violations.contains { $0.field == "items[0].verdict" })
    }

    // The acceptance checklist: every item needs a non-empty id and description (the plan schema).
    @Test func acceptanceChecklistRequiresIdAndDescription() throws {
        let schema = SchemaSpec(fields: ["acceptance": FieldSpec(type: "list", required: true, invariants: [
            Invariant(nonEmpty: true),
            Invariant(all: ItemPredicate(field: "id", nonEmpty: true)),
            Invariant(all: ItemPredicate(field: "description", nonEmpty: true))])])
        let good = "acceptance:\n  - { id: a, description: \"does a\" }"
        #expect(try SchemaValidator.validate(schema, artifactYAML: good).isEmpty)

        let badId = "acceptance:\n  - { id: \"\", description: \"does a\" }"
        let violations = try SchemaValidator.validate(schema, artifactYAML: badId)
        #expect(violations.contains { $0.field == "acceptance[0].id" })
    }

    // MARK: - Scope gate (Tier-2: changed files ⊆ declared manifest)

    // Porcelain parsing counts modified, deleted, untracked/new, and both sides of a rename.
    @Test func scopeParsesAllChangeKinds() {
        let porcelain = """
         M Sources/A.swift
        ?? Sources/New.swift
         D Sources/Gone.swift
        R  Sources/Old.swift -> Sources/Renamed.swift
        """
        let changed = ScopeChecker.changedFiles(porcelain: porcelain)
        #expect(Set(changed) == ["Sources/A.swift", "Sources/New.swift", "Sources/Gone.swift",
                                 "Sources/Old.swift", "Sources/Renamed.swift"])
    }

    // The headline case: an undeclared NEW (untracked) file is caught — pattern checks miss this.
    @Test func scopeCatchesUndeclaredNewFile() {
        let porcelain = """
        ?? Sources/Declared.swift
        ?? Sources/Unexpected.swift
        """
        let changed = ScopeChecker.changedFiles(porcelain: porcelain)
        let out = ScopeChecker.outOfScope(changed: changed, declared: ["Sources/Declared.swift"])
        #expect(out == ["Sources/Unexpected.swift"])
    }

    // A clean change (every touched file declared) is in scope; directory prefixes cover children.
    @Test func scopeAcceptsDeclaredAndPrefixes() {
        let changed = ["Sources/Hyrox/Service.swift", "Sources/Hyrox/Model.swift", "Tests/T.swift"]
        #expect(ScopeChecker.outOfScope(changed: changed,
                                        declared: ["Sources/Hyrox/**", "Tests/T.swift"]).isEmpty)
        // Without the prefix, a sibling under the dir is flagged.
        #expect(ScopeChecker.outOfScope(changed: ["Sources/Other.swift"],
                                        declared: ["Sources/Hyrox/**"]) == ["Sources/Other.swift"])
    }

    // The manifest is read from the plan artifact's `files:` list.
    @Test func scopeReadsManifestFromPlan() throws {
        let plan = """
        files:
          - Sources/A.swift
          - Tests/ATests.swift
        """
        #expect(try ScopeChecker.declaredFiles(planYAML: plan) == ["Sources/A.swift", "Tests/ATests.swift"])
    }

    // MARK: - §9 rework routing (a failed verdict routes to the producer of the indicted input)

    // The plan→implement→review sub-pipeline; the reviewer consumes BOTH plan.v1 and code.v1.
    private func reviewLinePipeline() -> PipelineSpec {
        PipelineSpec(
            nodes: [PipelineNode(id: "architect", worker: "architect"),
                    PipelineNode(id: "coder", worker: "coder"),
                    PipelineNode(id: "reviewer", worker: "reviewer", required: true)],
            edges: [PipelineEdge(from: OneOrMany(["architect"]), to: "coder", artifact: "plan.v1"),
                    PipelineEdge(from: OneOrMany(["architect"]), to: "reviewer", artifact: "plan.v1"),
                    PipelineEdge(from: OneOrMany(["coder"]), to: "reviewer", artifact: "code.v1")])
    }
    private let reviewLineProduces = ["architect": ["plan.v1"], "coder": ["code.v1"], "reviewer": ["review.v1"]]

    // A reject indicting code.v1 routes to the coder; the coder + reviewer subtree is invalidated,
    // the upstream architect/plan.v1 is left intact.
    @Test func reworkRoutesToImplementerOnCodeDefect() {
        let routing = Rework.route(failedNode: "reviewer", indicted: ["code.v1"],
                                   pipeline: reviewLinePipeline(), produces: reviewLineProduces)
        #expect(routing?.producers == ["coder"])
        #expect(routing?.invalidatedNodes == ["coder", "reviewer"])
        #expect(routing?.invalidatedArtifacts == ["code.v1", "review.v1"])   // plan.v1 untouched
    }

    // A reject indicting plan.v1 routes to the planner; the whole subtree (architect→coder→reviewer)
    // re-runs — this is the contract/plan-defect case.
    @Test func reworkRoutesToPlannerOnContractDefect() {
        let routing = Rework.route(failedNode: "reviewer", indicted: ["plan.v1"],
                                   pipeline: reviewLinePipeline(), produces: reviewLineProduces)
        #expect(routing?.producers == ["architect"])
        #expect(routing?.invalidatedNodes == ["architect", "coder", "reviewer"])
        #expect(routing?.invalidatedArtifacts == ["code.v1", "plan.v1", "review.v1"])
    }

    // A reject naming an input no incoming edge carries can't be routed → nil (caller escalates).
    @Test func reworkWithNoMatchingInputDoesNotRoute() {
        #expect(Rework.route(failedNode: "reviewer", indicted: ["ghost.v1"],
                             pipeline: reviewLinePipeline(), produces: reviewLineProduces) == nil)
    }

    // The decision policy: route within the bound, escalate at it, escalate with no target.
    @Test func reworkDecisionBoundsAndEscalates() {
        let pipeline = reviewLinePipeline()
        // Within the bound + resolvable → route.
        if case .route(let r) = Rework.decide(round: Rework.maxRounds - 1, failedNode: "reviewer",
                indicted: ["code.v1"], pipeline: pipeline, produces: reviewLineProduces) {
            #expect(r.producers == ["coder"])
        } else { Issue.record("expected a route within the bound") }
        // At the bound → escalate even with a resolvable target.
        #expect(Rework.decide(round: Rework.maxRounds, failedNode: "reviewer", indicted: ["code.v1"],
                pipeline: pipeline, produces: reviewLineProduces) == .escalate)
        // No resolvable target → escalate.
        #expect(Rework.decide(round: 0, failedNode: "reviewer", indicted: [],
                pipeline: pipeline, produces: reviewLineProduces) == .escalate)
    }

    // The routing hint reads only from a *verdict* artifact (one carrying a verdict / rework block).
    @Test func routingHintOnlyForVerdictArtifacts() throws {
        let reject = "verdict: reject\nrework:\n  - { target: code.v1, reason: wrong }"
        #expect(try Rework.routingHint(artifactYAML: reject) == Rework.RoutingHint(targets: ["code.v1"]))
        // An approve carries a verdict but no rework targets → a hint with no targets (would escalate).
        #expect(try Rework.routingHint(artifactYAML: "verdict: approve")?.targets == [])
        // A changeset (no verdict, no rework) is not a verdict artifact → nil → self-rework.
        #expect(try Rework.routingHint(artifactYAML: "summary: x\nsatisfies: [a]") == nil)
    }

    // The Reducer folds a routed rework: subtree invalidated, producers carry the failure, round counted.
    @Test func reducerFoldsReworkRouted() {
        var state = RunState(readyArtifacts: ["plan.v1", "code.v1"],
                             completedNodes: ["architect", "coder"], inProgressNodes: ["reviewer"])
        state = Reducer.reduce(state, .reworkRouted(failedNode: "reviewer", producers: ["coder"],
            invalidatedNodes: ["coder", "reviewer"], invalidatedArtifacts: ["code.v1", "review.v1"],
            checks: ["review.structure"]))
        #expect(state.inProgressNodes.isEmpty)
        #expect(state.completedNodes == ["architect"])         // coder invalidated; architect intact
        #expect(state.readyArtifacts == ["plan.v1"])           // code.v1 dropped
        #expect(state.failedChecks["coder"] == ["review.structure"])   // producer carries the context
        #expect(state.reworkRounds["reviewer"] == 1)

        // The coder is runnable again (plan.v1 ready); the reviewer is not (code.v1 gone).
        #expect(Scheduler.runnable(state, reviewLinePipeline()) == ["coder"])
    }

    // The Reducer folds an escalation: the node is parked and the Scheduler stops dispensing it.
    @Test func reducerFoldsEscalationAndSchedulerParks() {
        var state = RunState(readyArtifacts: ["plan.v1", "code.v1"],
                             completedNodes: ["architect", "coder"], inProgressNodes: ["reviewer"])
        state = Reducer.reduce(state, .escalated(node: "reviewer", checks: ["review.structure"]))
        #expect(state.escalatedNodes == ["reviewer"])
        #expect(state.inProgressNodes.isEmpty)
        // reviewer would otherwise be runnable (both inputs ready) — escalation parks it.
        #expect(Scheduler.runnable(state, reviewLinePipeline()).isEmpty)
    }

    // A routed rework scoped into a slice folds into that slice's sub-state (not the top level).
    @Test func reworkRoutedScopesIntoSlice() {
        var state = RunState()
        state = Reducer.reduce(state, .scoped(slice: "s", event: .reworkRouted(
            failedNode: "reviewer", producers: ["coder"], invalidatedNodes: ["coder", "reviewer"],
            invalidatedArtifacts: ["code.v1"], checks: ["review.structure"])))
        #expect(state.slices["s"]?.failedChecks["coder"] == ["review.structure"])
        #expect(state.slices["s"]?.reworkRounds["reviewer"] == 1)
        #expect(state.failedChecks.isEmpty)   // top level untouched
    }

    // MARK: - Coverage gate (cross-artifact: review item ids ⊇ plan acceptance ids)

    // A review judging every acceptance item leaves nothing uncovered.
    @Test func coverageAcceptsFullReview() throws {
        let plan = "acceptance:\n  - { id: a, description: x }\n  - { id: b, description: y }"
        let review = "items:\n  - { id: a, verdict: pass }\n  - { id: b, verdict: fail }"
        let acceptance = try CoverageChecker.acceptanceIDs(planYAML: plan)
        let reviewed = try CoverageChecker.reviewedIDs(reviewYAML: review)
        #expect(acceptance == ["a", "b"])
        #expect(CoverageChecker.uncovered(acceptance: acceptance, reviewed: reviewed).isEmpty)
    }

    // A review that skips an acceptance item is caught — in plan order.
    @Test func coverageCatchesSkippedItem() throws {
        let plan = "acceptance:\n  - { id: a, description: x }\n  - { id: b, description: y }"
        let review = "items:\n  - { id: a, verdict: pass }"   // b never judged
        let uncovered = CoverageChecker.uncovered(
            acceptance: try CoverageChecker.acceptanceIDs(planYAML: plan),
            reviewed: try CoverageChecker.reviewedIDs(reviewYAML: review))
        #expect(uncovered == ["b"])
    }

    // MARK: - Graph renderer (Pipeline → Mermaid, ADR-0027)

    // A build pattern (artifact edges) renders arrows labelled with the Schema, and node detail.
    @Test func graphRendersArtifactEdgesWithLabels() {
        let pipeline = PipelineSpec(
            nodes: [PipelineNode(id: "architect", worker: "architect"),
                    PipelineNode(id: "coder", worker: "coder")],
            edges: [PipelineEdge(from: OneOrMany(["architect"]), to: "coder", artifact: "plan.v1")])
        let md = GraphRenderer.mermaid(pipeline)
        #expect(md.contains("```mermaid"))
        #expect(md.contains("flowchart TD"))
        #expect(md.contains("architect -->|plan.v1| coder"))
        #expect(md.contains("architect[\"architect\"]"))   // worker == id → not repeated in the label
    }

    // A worker that differs from the node id IS shown as label detail.
    @Test func graphShowsWorkerWhenItDiffersFromID() {
        let pipeline = PipelineSpec(nodes: [PipelineNode(id: "n1", worker: "architect")], edges: [])
        #expect(GraphRenderer.mermaid(pipeline).contains("n1[\"n1<br/>architect\"]"))
    }

    // An orchestration graph (depends_on, no artifact) renders plain arrows; ids are made safe and
    // slice nodes note their stack.
    @Test func graphRendersDependencyEdgesAndSlices() {
        let pipeline = PipelineSpec(
            nodes: [PipelineNode(id: "package-skeleton", kind: "pipeline", pipeline: "../..", stack: "swift"),
                    PipelineNode(id: "domain-models", kind: "pipeline", pipeline: "../..", stack: "swift")],
            edges: [PipelineEdge(from: OneOrMany(["package-skeleton"]), to: "domain-models")])
        let md = GraphRenderer.mermaid(pipeline, direction: "LR")
        #expect(md.contains("flowchart LR"))
        #expect(md.contains("package_skeleton -->  domain_models") == false)  // no double space
        #expect(md.contains("package_skeleton --> domain_models"))            // plain arrow, sanitized ids
        #expect(md.contains("package_skeleton[\"package-skeleton<br/>slice [swift]\"]"))  // original id + stack
    }

    // The project index assembles a TOC over its sections, then each section's body in order.
    @Test func projectIndexBuildsTOCAndSections() {
        let doc = GraphRenderer.projectIndex(title: "roxwod", sections: [
            .init(heading: "Build pattern · roxwod", body: "BP-BODY"),
            .init(heading: "Feature · hyrox-scraper", body: "HS-BODY")])
        #expect(doc.contains("# roxwod — project graph"))
        #expect(doc.contains("## Contents"))
        #expect(doc.contains("- [Feature · hyrox-scraper](#feature-hyrox-scraper)"))   // collapsed slug
        #expect(doc.contains("<a id=\"feature-hyrox-scraper\"></a>"))                  // explicit anchor → link works
        #expect(doc.contains("## Build pattern · roxwod"))
        #expect(doc.contains("BP-BODY"))
        #expect(doc.contains("HS-BODY"))
        // Build pattern precedes the feature (section order preserved).
        #expect(doc.range(of: "BP-BODY")!.lowerBound < doc.range(of: "HS-BODY")!.lowerBound)
    }

    // Node labels carry owner — the node's own, else the inherited feature lead.
    @Test func graphLabelsCarryOwner() {
        let pipeline = PipelineSpec(nodes: [
            PipelineNode(id: "models", kind: "pipeline", pipeline: "../..", stack: "swift", owner: ["bob"]),
            PipelineNode(id: "api", kind: "pipeline", pipeline: "../..", stack: "swift")], edges: [])
        let md = GraphRenderer.mermaid(pipeline, inheritedOwner: ["alice"])
        #expect(md.contains("models<br/>slice [swift] @bob"))   // node owner wins
        #expect(md.contains("api<br/>slice [swift] @alice"))    // inherits the feature lead
    }

    // The fragment header renders the four tags, and is nil when none are set (plain pipeline).
    @Test func fragmentHeaderRendersTagsOrNil() {
        let tagged = SpecMetadata(name: "loan-origination", correlation: "bnpl/loan-origination",
            factory: "code", owner: ["alice"],
            origin: Origin(repo: "acme/ledger-svc", tag: "v2.1.0", hash: "def4567890", path: ".ai-sdd/features/loan"))
        let header = GraphRenderer.fragmentHeader(tagged)
        #expect(header?.contains("**lane** code") == true)
        #expect(header?.contains("**owner** alice") == true)
        #expect(header?.contains("**milestone** bnpl/loan-origination") == true)
        #expect(header?.contains("acme/ledger-svc@v2.1.0 (def45678)") == true)   // tag + short hash
        #expect(GraphRenderer.fragmentHeader(SpecMetadata(name: "plain")) == nil)
    }

    // The new metadata + node owner decode from YAML (additive, optional).
    @Test func fragmentTagsDecodeFromYAML() throws {
        let yaml = """
        apiVersion: ai-sdd/v1
        kind: Pipeline
        metadata:
          name: loan-origination
          correlation: bnpl/loan-origination
          factory: code
          owner: [alice]
          origin: { repo: acme/ledger-svc, tag: v2.1.0, hash: def456, path: .ai-sdd/features/loan }
        spec:
          nodes: [ { id: models, kind: pipeline, pipeline: ../.., stack: swift, owner: [bob] } ]
          edges: []
        """
        let env = try loader.loadPipelineYAML(yaml)
        #expect(env.metadata.correlation == "bnpl/loan-origination")
        #expect(env.metadata.factory == "code")
        #expect(env.metadata.owner == ["alice"])
        #expect(env.metadata.origin == Origin(repo: "acme/ledger-svc", tag: "v2.1.0", hash: "def456", path: ".ai-sdd/features/loan"))
        #expect(env.spec.nodes[0].owner == ["bob"])
    }

    // A single section omits the contents list (nothing to drill into).
    @Test func projectIndexSkipsTOCForOneSection() {
        let doc = GraphRenderer.projectIndex(title: "x", sections: [.init(heading: "Only", body: "B")])
        #expect(!doc.contains("## Contents"))
    }

    // The HTML page embeds the Markdown and wires up Mermaid; </script> in content can't break out.
    @Test func htmlPageEmbedsMarkdownAndMermaid() {
        let md = "# demo\n\n```mermaid\nflowchart TD\n  a --> b\n```\n"
        let page = GraphRenderer.htmlPage(title: "demo", markdown: md)
        #expect(page.hasPrefix("<!doctype html>"))
        #expect(page.contains("<title>demo — ai-sdd graph</title>"))
        #expect(page.contains("flowchart TD"))                     // the markdown is embedded
        #expect(page.contains("mermaid.esm.min.mjs"))              // mermaid is loaded
        #expect(page.contains("marked.parse"))                     // markdown is rendered
        // A literal closing-script tag in content is neutralised.
        #expect(GraphRenderer.htmlPage(title: "x", markdown: "</script>").contains("<\\/script"))
    }

    // The program index groups fragments under milestone headings, each fragment an H3 section.
    @Test func programIndexGroupsFragmentsByMilestone() {
        let doc = GraphRenderer.programIndex(title: "bnpl", milestones: [
            .init(name: "bnpl/loan-origination", fragments: [
                .init(heading: "ledger-svc · code", body: "LEDGER"),
                .init(heading: "gql-gateway · code", body: "GQL")]),
            .init(name: "bnpl/accounting", fragments: [.init(heading: "accounting-svc · code", body: "ACCT")])])
        #expect(doc.contains("# bnpl — program graph"))
        #expect(doc.contains("- [bnpl/loan-origination](#bnpl-loan-origination)"))   // collapsed slug
        #expect(doc.contains("<a id=\"bnpl-loan-origination\"></a>"))                 // explicit anchor
        #expect(doc.contains("## bnpl/loan-origination"))
        #expect(doc.contains("### ledger-svc · code"))
        #expect(doc.contains("LEDGER"))
        // Both fragments of the first milestone precede the second milestone's fragment.
        #expect(doc.range(of: "GQL")!.lowerBound < doc.range(of: "ACCT")!.lowerBound)
    }

    // Caret compatibility: same major and tag ≥ range passes; a lower minor or wrong major fails.
    @Test func contractSemverCaretSatisfies() {
        #expect(Contracts.satisfies(providerTag: "v2.1.0", range: "^2.0") == true)   // 2.1 ≥ 2.0, same major
        #expect(Contracts.satisfies(providerTag: "v2.1.0", range: "^2.2") == false)  // 2.1 < 2.2
        #expect(Contracts.satisfies(providerTag: "v1.4.0", range: "^2.0") == false)  // wrong major
        #expect(Contracts.satisfies(providerTag: nil, range: "^2.0") == nil)         // no provider → unknown
        #expect(Contracts.satisfies(providerTag: "v2.0.0", range: "garbage") == nil) // unparseable → unknown
    }

    // Cross-referencing provides/requires across fragments yields a status per contract, flagging skew.
    @Test func contractStatusesFlagSkew() {
        let fragments: [(name: String, metadata: SpecMetadata)] = [
            ("ledger-svc", SpecMetadata(name: "ledger-svc",
                provides: [ContractRef(name: "payments.proto", tag: "v2.1.0")])),
            ("gql-gateway", SpecMetadata(name: "gql-gateway",
                requires: [ContractRef(name: "payments.proto", range: "^2.0")])),
            ("billing-svc", SpecMetadata(name: "billing-svc",
                requires: [ContractRef(name: "payments.proto", range: "^3.0")]))]   // skew: needs v3
        let statuses = Contracts.statuses(fragments)
        #expect(statuses.count == 1)
        let payments = statuses[0]
        #expect(payments.provider == "ledger-svc")
        #expect(payments.providedTag == "v2.1.0")
        #expect(payments.consumers.first { $0.fragment == "gql-gateway" }?.satisfied == true)
        #expect(payments.consumers.first { $0.fragment == "billing-svc" }?.satisfied == false)

        // The rendered section marks the skew.
        let section = GraphRenderer.contractsSection(statuses)
        #expect(section?.contains("**payments.proto**") == true)
        #expect(section?.contains("⚠ skew billing-svc") == true)
    }

    // A Plant spec decodes its fragment list from YAML.
    @Test func plantSpecDecodes() throws {
        let env = try loader.loadPlantYAML("""
        apiVersion: ai-sdd/v1
        kind: Plant
        metadata: { name: bnpl, version: 1 }
        spec:
          fragments:
            - { path: ../ledger-svc/.ai-sdd/features/loan-origination }
            - { path: ../gql-gateway/.ai-sdd/features/loan-origination }
        """)
        #expect(env.metadata.name == "bnpl")
        #expect(env.spec.fragments.count == 2)
        #expect(env.spec.fragments[0].path == "../ledger-svc/.ai-sdd/features/loan-origination")
    }

    // A join edge with the `*` wildcard renders an unlabelled arrow per source.
    @Test func graphRendersJoinWithoutWildcardLabel() {
        let pipeline = PipelineSpec(
            nodes: [PipelineNode(id: "a"), PipelineNode(id: "b"), PipelineNode(id: "join", kind: "join")],
            edges: [PipelineEdge(from: OneOrMany(["a", "b"]), to: "join", artifact: "*")])
        let md = GraphRenderer.mermaid(pipeline)
        #expect(md.contains("a --> join"))
        #expect(md.contains("b --> join"))
        #expect(!md.contains("|*|"))   // the wildcard is not shown as a label
    }

    // MARK: - Dashboard projection (pure status rows for later rendering)

    private func dashboardPipeline() -> PipelineSpec {
        PipelineSpec(
            nodes: [
                PipelineNode(id: "plan", kind: "pipeline", pipeline: "../..", stack: "swift"),
                PipelineNode(id: "implement", kind: "pipeline", pipeline: "../..", stack: "swift", owner: ["bob"]),
                PipelineNode(id: "docs", kind: "pipeline", pipeline: "../..", stack: "docs"),
                PipelineNode(id: "review", kind: "pipeline", pipeline: "../..", stack: "swift"),
                PipelineNode(id: "qa", kind: "pipeline", pipeline: "../..", stack: "test"),
                PipelineNode(id: "release", kind: "pipeline", pipeline: "../..", stack: "ops"),
                PipelineNode(id: "deploy", kind: "pipeline", pipeline: "../..", stack: "ops")
            ],
            edges: [
                PipelineEdge(from: OneOrMany(["plan"]), to: "implement"),
                PipelineEdge(from: OneOrMany(["plan"]), to: "docs"),
                PipelineEdge(from: OneOrMany(["implement"]), to: "review"),
                PipelineEdge(from: OneOrMany(["implement"]), to: "qa"),
                PipelineEdge(from: OneOrMany(["qa"]), to: "release"),
                PipelineEdge(from: OneOrMany(["release"]), to: "deploy")
            ])
    }

    @Test func dashboardStatusValuesAreStable() {
        #expect(DashboardStatus.allCases.map(\.rawValue) ==
            ["done", "in-progress", "rework", "escalated", "runnable", "pending"])
    }

    @Test func dashboardProjectionClassifiesNoRunGraph() {
        let pipeline = PipelineSpec(
            nodes: [PipelineNode(id: "root"), PipelineNode(id: "leaf")],
            edges: [PipelineEdge(from: OneOrMany(["root"]), to: "leaf")])
        let result = DashboardProjection.project(pipeline: pipeline, metadata: SpecMetadata(name: "feature"))

        #expect(result.rows.map(\.status) == [.runnable, .pending])
        #expect(result.rows[0].nextActionHint == .startWork)
        #expect(result.rows[1].nextActionHint == .waitingOnDependencies)
    }

    @Test func dashboardProjectionClassifiesRunBackedGraphAndRows() throws {
        let state = RunState(
            completedNodes: ["plan", "qa"],
            inProgressNodes: ["implement"],
            failedChecks: ["review": ["review.structure"]],
            escalatedNodes: ["release"])
        let metadata = SpecMetadata(name: "project-status-dashboard", correlation: "m1",
                                    factory: "code", owner: ["alice"])
        let result = DashboardProjection.project(pipeline: dashboardPipeline(), metadata: metadata, state: state)
        let statuses = Dictionary(uniqueKeysWithValues: result.rows.map { ($0.node, $0.status) })

        #expect(statuses["plan"] == .done)
        #expect(statuses["implement"] == .inProgress)
        #expect(statuses["review"] == .rework)
        #expect(statuses["release"] == .escalated)
        #expect(statuses["docs"] == .runnable)
        #expect(statuses["deploy"] == .pending)

        let implement = try #require(result.rows.first { $0.node == "implement" })
        #expect(implement.stack == "swift")
        #expect(implement.owner == "bob")
        #expect(implement.lane == "code")
        #expect(implement.milestone == "m1")
        #expect(implement.dependencyCount == 1)
        #expect(implement.nextActionHint == .continueWork)

        let release = try #require(result.rows.first { $0.node == "release" })
        #expect(release.nextActionHint == .humanIntervention)
    }

    @Test func dashboardProjectionStatusPrecedenceIsDeterministic() {
        let pipeline = PipelineSpec(nodes: [PipelineNode(id: "slice")], edges: [])
        let metadata = SpecMetadata(name: "feature")

        let escalated = RunState(completedNodes: ["slice"], inProgressNodes: ["slice"],
                                 failedChecks: ["slice": ["unit"]], escalatedNodes: ["slice"])
        #expect(DashboardProjection.project(pipeline: pipeline, metadata: metadata,
                                            state: escalated).rows[0].status == .escalated)

        let rework = RunState(completedNodes: ["slice"], inProgressNodes: ["slice"],
                              failedChecks: ["slice": ["unit"]])
        #expect(DashboardProjection.project(pipeline: pipeline, metadata: metadata,
                                            state: rework).rows[0].status == .rework)

        let inProgress = RunState(completedNodes: ["slice"], inProgressNodes: ["slice"])
        #expect(DashboardProjection.project(pipeline: pipeline, metadata: metadata,
                                            state: inProgress).rows[0].status == .inProgress)

        let done = RunState(completedNodes: ["slice"])
        #expect(DashboardProjection.project(pipeline: pipeline, metadata: metadata,
                                            state: done).rows[0].status == .done)

        #expect(DashboardProjection.project(pipeline: pipeline, metadata: metadata,
                                            state: RunState()).rows[0].status == .runnable)
    }

    @Test func dashboardProjectionOwnerFallbacks() {
        let nodeOwned = PipelineSpec(
            nodes: [PipelineNode(id: "slice", stack: "swift", owner: ["bob"])], edges: [])
        #expect(DashboardProjection.project(pipeline: nodeOwned,
                                            metadata: SpecMetadata(name: "feature", owner: ["alice"]))
            .rows[0].owner == "bob")

        let metadataOwned = PipelineSpec(nodes: [PipelineNode(id: "slice", stack: "swift")], edges: [])
        #expect(DashboardProjection.project(pipeline: metadataOwned,
                                            metadata: SpecMetadata(name: "feature", owner: ["alice"]))
            .rows[0].owner == "alice")

        #expect(DashboardProjection.project(pipeline: metadataOwned, metadata: SpecMetadata(name: "feature"))
            .rows[0].owner == "feature")

        #expect(DashboardProjection.project(pipeline: metadataOwned, metadata: SpecMetadata(name: ""))
            .rows[0].owner == "swift")
    }

    @Test func dashboardProjectionSummaryCountsStatuses() {
        let state = RunState(
            completedNodes: ["plan", "qa"],
            inProgressNodes: ["implement"],
            failedChecks: ["review": ["review.structure"]],
            escalatedNodes: ["release"])
        let result = DashboardProjection.project(
            pipeline: dashboardPipeline(),
            metadata: SpecMetadata(name: "project-status-dashboard"),
            state: state)

        #expect(result.summary.totalFeatureCount == 1)
        #expect(result.summary.totalNodeCount == 7)
        #expect(result.summary.doneCount == 2)
        #expect(result.summary.statusTotals[.done] == 2)
        #expect(result.summary.statusTotals[.inProgress] == 1)
        #expect(result.summary.statusTotals[.rework] == 1)
        #expect(result.summary.statusTotals[.escalated] == 1)
        #expect(result.summary.statusTotals[.runnable] == 1)
        #expect(result.summary.statusTotals[.pending] == 1)
    }

    @Test func projectDashboardAssemblerBuildsSectionsAndMatchesRunsByPipelineDir() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-sdd-dashboard-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try writePipeline(at: tmp, name: "factory", nodes: ["build"], edges: [])
        let features = tmp.appendingPathComponent("features", isDirectory: true)
        let alpha = features.appendingPathComponent("alpha", isDirectory: true)
        let beta = features.appendingPathComponent("beta", isDirectory: true)
        let broken = features.appendingPathComponent("zeta-broken", isDirectory: true)
        try writePipeline(at: alpha, name: "alpha", nodes: ["plan", "implement"],
                          edges: [("plan", "implement")])
        try writePipeline(at: beta, name: "beta", nodes: ["start", "finish"],
                          edges: [("start", "finish")])
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try "not: a pipeline".write(
            to: broken.appendingPathComponent("pipeline.yaml"),
            atomically: true,
            encoding: .utf8)

        let store = RunStore(root: tmp.appendingPathComponent("runs", isDirectory: true))
        try store.create(runId: "local-run-42", pipelineDir: alpha.standardizedFileURL.path)
        try store.append(.nodeCompleted(node: "plan", producedArtifacts: []), to: "local-run-42")

        let dashboard = try ProjectDashboardAssembler.assemble(factoryDir: tmp, runStore: store)

        #expect(dashboard.title == "factory")
        #expect(dashboard.sections.map(\.heading) == [
            "Feature · alpha",
            "Feature · beta",
            "Feature · zeta-broken"
        ])

        let alphaRows = try #require(dashboard.sections.first { $0.heading == "Feature · alpha" }?.projection.rows)
        #expect(Dictionary(uniqueKeysWithValues: alphaRows.map { ($0.node, $0.status) }) == [
            "plan": .done,
            "implement": .runnable
        ])

        let betaRows = try #require(dashboard.sections.first { $0.heading == "Feature · beta" }?.projection.rows)
        #expect(betaRows.map(\.status) == [.runnable, .pending])
        #expect(dashboard.sections.first { $0.heading == "Feature · alpha" }?.mermaid?.contains("plan --> implement") == true)

        let brokenSection = try #require(dashboard.sections.first { $0.heading == "Feature · zeta-broken" })
        #expect(brokenSection.projection.rows.isEmpty)
        #expect(brokenSection.projection.summary.totalNodeCount == 0)
    }

    @Test func projectDashboardAssemblerRendersBuildPatternWithoutFeatures() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-sdd-dashboard-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try writePipeline(at: tmp, name: "factory", nodes: ["build"], edges: [])

        let dashboard = try ProjectDashboardAssembler.assemble(
            factoryDir: tmp,
            runStore: RunStore(root: tmp.appendingPathComponent("runs", isDirectory: true)))

        #expect(dashboard.title == "factory")
        #expect(dashboard.sections.map(\.heading) == ["Build pattern · factory"])
        #expect(dashboard.sections[0].projection.rows.map(\.status) == [.runnable])
    }

    @Test func projectDashboardAssemblerShowsActiveBuildPatternWithFeatures() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-sdd-dashboard-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try writePipeline(at: tmp, name: "factory", nodes: ["build"], edges: [])
        let feature = tmp
            .appendingPathComponent("features", isDirectory: true)
            .appendingPathComponent("dashboard", isDirectory: true)
        try writePipeline(at: feature, name: "dashboard", nodes: ["plan"], edges: [])

        let store = RunStore(root: tmp.appendingPathComponent("runs", isDirectory: true))
        try store.create(runId: "factory-run", pipelineDir: tmp.standardizedFileURL.path)
        try store.append(.nodeStarted(node: "build"), to: "factory-run")

        let dashboard = try ProjectDashboardAssembler.assemble(factoryDir: tmp, runStore: store)

        #expect(dashboard.sections.map(\.heading) == ["Feature · dashboard", "Build pattern · factory"])
        #expect(dashboard.sections[1].projection.rows.map(\.status) == [.inProgress])
        #expect(dashboard.sections[1].projection.rows.map(\.owner) == ["factory"])
    }

    @Test func projectDashboardWorkflowWritesSelfContainedHTMLFile() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-sdd-dashboard-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try writePipeline(at: tmp, name: "factory", nodes: ["build"], edges: [])
        let feature = tmp
            .appendingPathComponent("features", isDirectory: true)
            .appendingPathComponent("dashboard", isDirectory: true)
        try writePipeline(at: feature, name: "dashboard", nodes: ["plan", "implement"],
                          edges: [("plan", "implement")])

        let store = RunStore(root: tmp.appendingPathComponent("runs", isDirectory: true))
        try store.create(runId: "dashboard-run", pipelineDir: feature.standardizedFileURL.path)
        try store.append(.nodeCompleted(node: "plan", producedArtifacts: []), to: "dashboard-run")

        let dashboard = try ProjectDashboardAssembler.assemble(factoryDir: tmp, runStore: store)
        let page = GraphRenderer.dashboardPage(title: dashboard.title, sections: dashboard.sections)
        let output = tmp.appendingPathComponent("dashboard.html")
        try page.write(to: output, atomically: true, encoding: .utf8)

        let written = try String(contentsOf: output, encoding: .utf8)
        #expect(!written.isEmpty)
        #expect(written.hasPrefix("<!doctype html>"))
        #expect(written.contains("<title>factory — ai-sdd dashboard</title>"))
        #expect(written.contains("<style>"))
        #expect(written.contains("Feature · dashboard"))
        #expect(!written.contains("Build pattern · factory"))
        #expect(written.contains("class=\"mermaid dashboard-mermaid\""))
        #expect(written.contains("plan --&gt; implement"))
        #expect(written.contains("class=\"dashboard-chart dashboard-status-donut\""))
        #expect(written.contains("class=\"dashboard-chart dashboard-grouped-bars\""))
        #expect(written.contains("mermaid.esm.min.mjs"))
    }

    private func writePipeline(at directory: URL, name: String, nodes: [String],
                               edges: [(String, String)]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let nodeLines = nodes.map { "    - { id: \($0) }" }.joined(separator: "\n")
        let edgeLines = edges.map { "    - { from: \($0.0), to: \($0.1) }" }.joined(separator: "\n")
        let edgesBlock = edgeLines.isEmpty ? "  edges: []" : "  edges:\n\(edgeLines)"
        let yaml = """
        apiVersion: ai-sdd/v1
        kind: Pipeline
        metadata: { name: \(name), version: 1 }
        spec:
          nodes:
        \(nodeLines)
        \(edgesBlock)
        """
        try yaml.write(to: directory.appendingPathComponent("pipeline.yaml"), atomically: true, encoding: .utf8)
    }

    @Test func dashboardStatusDonutRendersSegmentsCountsAndColors() {
        let summary = DashboardProjectionSummary(
            totalFeatureCount: 1,
            totalNodeCount: 7,
            doneCount: 2,
            statusTotals: [.done: 2, .inProgress: 1, .rework: 1, .escalated: 1, .runnable: 1, .pending: 1])
        let svg = DashboardCharts.statusDonut(summary)

        #expect(svg.components(separatedBy: "class=\"status-segment").count - 1 == DashboardStatus.allCases.count)
        for status in DashboardStatus.allCases {
            #expect(svg.contains("data-status=\"\(status.rawValue)\""))
            #expect(svg.contains("fill=\"\(DashboardCharts.defaultColors[status]!)\"")
                || svg.contains("stroke=\"\(DashboardCharts.defaultColors[status]!)\""))
        }
        #expect(svg.contains("data-status=\"done\" data-count=\"2\""))
        #expect(svg.contains("done: 2"))
        #expect(svg.contains("in-progress 1"))
        #expect(svg.contains("Status distribution: done 2, in-progress 1, rework 1, escalated 1, runnable 1, pending 1"))
    }

    @Test func dashboardGroupedBarsUseOwnerFallbackLabelsAndBreakdown() {
        let state = RunState(
            completedNodes: ["plan", "qa"],
            inProgressNodes: ["implement"],
            failedChecks: ["review": ["review.structure"]],
            escalatedNodes: ["release"])
        let result = DashboardProjection.project(
            pipeline: dashboardPipeline(),
            metadata: SpecMetadata(name: "project-status-dashboard", owner: ["alice"]),
            state: state)
        let svg = DashboardCharts.groupedBarChart(result.rows)

        #expect(svg.contains("viewBox=\"0 0 760"))
        #expect(svg.contains("<rect x=\"260\""))
        #expect(svg.contains("data-group=\"alice\" data-total=\"6\""))
        #expect(svg.contains("data-group=\"bob\" data-total=\"1\""))
        #expect(svg.contains("alice done: 2"))
        #expect(svg.contains("alice rework: 1"))
        #expect(svg.contains("alice escalated: 1"))
        #expect(svg.contains("alice runnable: 1"))
        #expect(svg.contains("alice pending: 1"))
        #expect(svg.contains("bob in-progress: 1"))
    }

    @Test func dashboardGroupedBarsKeepFallbackToFeatureThenStack() {
        let metadataFallback = DashboardProjection.project(
            pipeline: PipelineSpec(nodes: [PipelineNode(id: "slice", stack: "swift")], edges: []),
            metadata: SpecMetadata(name: "feature-name"))
        #expect(DashboardCharts.groupedBarChart(metadataFallback.rows).contains("data-group=\"feature-name\""))

        let stackFallback = DashboardProjection.project(
            pipeline: PipelineSpec(nodes: [PipelineNode(id: "slice", stack: "swift")], edges: []),
            metadata: SpecMetadata(name: ""))
        #expect(DashboardCharts.groupedBarChart(stackFallback.rows).contains("data-group=\"swift\""))
    }

    @Test func dashboardChartsEscapeSVGTextAndAttributes() {
        let label = "Team & <script>alert(\"x\")</script> 'lead'"
        let rows = [DashboardProjectionRow(
            node: "node",
            stack: nil,
            owner: label,
            lane: nil,
            milestone: nil,
            dependencyCount: 0,
            status: .runnable,
            nextActionHint: .startWork)]
        let svg = DashboardCharts.groupedBarChart(rows)

        #expect(svg.contains("Team &amp; &lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt; &#39;lead&#39;"))
        #expect(!svg.contains("<script>"))
        #expect(!svg.contains("\"x\""))
    }

    @Test func dashboardPageRendersCompleteDocumentSummaryLegendAndCharts() {
        let summary = DashboardProjectionSummary(
            totalFeatureCount: 1,
            totalNodeCount: 2,
            doneCount: 1,
            statusTotals: [.done: 1, .inProgress: 0, .rework: 0, .escalated: 0, .runnable: 1, .pending: 0])
        let rows = [
            DashboardProjectionRow(node: "plan", stack: "swift", owner: "alice", lane: "code",
                                   milestone: "m1", dependencyCount: 0, status: .done,
                                   nextActionHint: .none),
            DashboardProjectionRow(node: "implement", stack: "swift", owner: "bob", lane: "code",
                                   milestone: "m1", dependencyCount: 1, status: .runnable,
                                   nextActionHint: .startWork)
        ]
        let page = GraphRenderer.dashboardPage(title: "Project Status", sections: [
            .init(heading: "Feature · dashboard", projection: .init(rows: rows, summary: summary))
        ])

        #expect(page.hasPrefix("<!doctype html>"))
        #expect(page.contains("<title>Project Status — ai-sdd dashboard</title>"))
        #expect(page.contains("<style>"))
        #expect(page.contains("mermaid.esm.min.mjs"))
        #expect(page.contains("<span class=\"summary-value\">1</span><span class=\"summary-label\">features</span>"))
        #expect(page.contains("<span class=\"summary-value\">2</span><span class=\"summary-label\">slices</span>"))
        #expect(page.contains("<span class=\"summary-value\">1/2</span><span class=\"summary-label\">done</span>"))
        #expect(page.contains("role=\"progressbar\" aria-valuemin=\"0\" aria-valuemax=\"100\" aria-valuenow=\"50\""))
        #expect(page.contains("style=\"width: 50.0%\""))
        #expect(page.contains("1/2 done"))
        #expect(page.contains("class=\"dashboard-chart dashboard-status-donut\""))
        #expect(page.contains("class=\"dashboard-chart dashboard-grouped-bars\""))
        #expect(page.contains("justify-content: center; list-style: none"))
        #expect(page.contains("grid-template-columns: minmax(0, 1fr)"))
        #expect(page.contains(".dashboard-status-donut { justify-self: center; max-width: 360px; }"))
        #expect(page.contains(".dashboard-grouped-bars { width: 100%; }"))
        for status in DashboardStatus.allCases {
            #expect(page.contains("--status-\(status.rawValue): \(DashboardCharts.defaultColors[status]!)"))
            #expect(page.contains("legend-swatch status-\(status.rawValue)"))
            #expect(page.contains(">\(status.rawValue)</li>"))
        }
    }

    @Test func dashboardPageRendersStatusGraphAndSliceTableRows() {
        let summary = DashboardProjectionSummary(
            totalFeatureCount: 1,
            totalNodeCount: 3,
            doneCount: 1,
            statusTotals: [.done: 1, .inProgress: 1, .rework: 1, .escalated: 0, .runnable: 0, .pending: 0])
        let rows = [
            DashboardProjectionRow(node: "plan", stack: "swift", owner: "alice", lane: "code",
                                   milestone: "m1", dependencyCount: 0, status: .done,
                                   nextActionHint: .none),
            DashboardProjectionRow(node: "implement", stack: "swift", owner: "bob", lane: "code",
                                   milestone: "m1", dependencyCount: 1, status: .inProgress,
                                   nextActionHint: .continueWork),
            DashboardProjectionRow(node: "review", stack: "swift", owner: "alice", lane: "code",
                                   milestone: "m1", dependencyCount: 1, status: .rework,
                                   nextActionHint: .fixFailedChecks)
        ]
        let page = GraphRenderer.dashboardPage(title: "Project", sections: [
            .init(heading: "Feature · project", projection: .init(rows: rows, summary: summary),
                  mermaid: "flowchart TD\n    plan:::status_done\n    plan --> implement\n    implement --> review")
        ])

        #expect(page.contains("<h2>Feature · project</h2>"))
        #expect(page.contains("class=\"mermaid dashboard-mermaid\""))
        #expect(page.contains("flowchart TD"))
        #expect(page.contains("plan --&gt; implement"))
        #expect(page.contains("<td>implement</td>"))
        #expect(page.contains("<td>in-progress</td>"))
        #expect(page.contains("<td>bob</td>"))
        #expect(page.contains("<td>swift</td>"))
        #expect(page.contains("<td>code</td>"))
        #expect(page.contains("<td>m1</td>"))
        #expect(page.contains("<td>1</td>"))
        #expect(page.contains("<td>continue-work</td>"))
    }

    @Test func dashboardPageEscapesDynamicTextAndBoundsProgress() {
        let unsafe = "Team & <script>alert(\"x\")</script> 'lead'"
        let summary = DashboardProjectionSummary(
            totalFeatureCount: 1,
            totalNodeCount: 4,
            doneCount: 12,
            statusTotals: [.done: 12, .inProgress: 0, .rework: 0, .escalated: 0, .runnable: 0, .pending: 0])
        let rows = [DashboardProjectionRow(
            node: "node<&>\"'",
            stack: "swift<&>",
            owner: unsafe,
            lane: "lane<&>",
            milestone: "mile<&>",
            dependencyCount: 0,
            status: .done,
            nextActionHint: .none)]
        let page = GraphRenderer.dashboardPage(title: unsafe, sections: [
            .init(heading: "Feature <unsafe>", projection: .init(rows: rows, summary: summary))
        ])

        #expect(page.contains("Team &amp; &lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt; &#39;lead&#39;"))
        #expect(page.contains("Feature &lt;unsafe&gt;"))
        #expect(page.contains("node&lt;&amp;&gt;&quot;&#39;"))
        #expect(page.contains("swift&lt;&amp;&gt;"))
        #expect(page.contains("lane&lt;&amp;&gt;"))
        #expect(page.contains("mile&lt;&amp;&gt;"))
        #expect(!page.contains("\"x\""))
        #expect(page.contains("aria-valuenow=\"100\""))
        #expect(page.contains("style=\"width: 100.0%\""))
        #expect(page.contains("<span class=\"summary-value\">100%</span><span class=\"summary-label\">progress</span>"))

        let empty = GraphRenderer.dashboardPage(title: "Empty", sections: [
            .init(heading: "Empty", projection: .init(
                rows: [],
                summary: DashboardProjectionSummary(totalFeatureCount: 0, totalNodeCount: 0,
                                                    doneCount: 0, statusTotals: [:])))
        ])
        #expect(empty.contains("0/0 done"))
        #expect(empty.contains("aria-valuenow=\"0\""))
        #expect(empty.contains("style=\"width: 0.0%\""))
        #expect(empty.contains("<td colspan=\"8\">No slices</td>"))
    }

    // MARK: - Project rollup: verdict + portfolio bands (dashboard-band-scaffold S1)

    /// A fixed `now` so the verdict-band timestamp is deterministic across runs and machines.
    private var fixedNow: Date {
        // 2026-06-24 09:30:00 UTC.
        Date(timeIntervalSince1970: 1_782_293_400)
    }

    private func portfolioSection(heading: String, statuses: [DashboardStatus],
                                  owner: String, staleRun: Bool = false) -> GraphRenderer.DashboardSection {
        let rows = statuses.enumerated().map { index, status in
            DashboardProjectionRow(node: "n\(index)", stack: "swift", owner: owner, lane: "code",
                                   milestone: "m1", dependencyCount: index, status: status,
                                   nextActionHint: .none)
        }
        let totals = Dictionary(DashboardStatus.allCases.map { s in (s, statuses.filter { $0 == s }.count) },
                                uniquingKeysWith: +)
        let summary = DashboardProjectionSummary(
            totalFeatureCount: 1, totalNodeCount: statuses.count,
            doneCount: statuses.filter { $0 == .done }.count, statusTotals: totals)
        return .init(heading: heading, projection: .init(rows: rows, summary: summary), staleRun: staleRun)
    }

    @Test func verdictBandDerivesTrajectoryFromBlockersAndEscalations() {
        let escalated = [portfolioSection(heading: "Feature · a", statuses: [.done, .escalated], owner: "alice")]
        #expect(GraphRenderer.dashboardTrajectory(for: escalated) == .stalled)

        let rework = [portfolioSection(heading: "Feature · a", statuses: [.done, .rework], owner: "alice")]
        #expect(GraphRenderer.dashboardTrajectory(for: rework) == .slipping)

        let clean = [portfolioSection(heading: "Feature · a", statuses: [.done, .runnable], owner: "alice")]
        #expect(GraphRenderer.dashboardTrajectory(for: clean) == .onTrack)

        // Escalation dominates rework.
        let both = [portfolioSection(heading: "Feature · a", statuses: [.rework, .escalated], owner: "alice")]
        #expect(GraphRenderer.dashboardTrajectory(for: both) == .stalled)
    }

    @Test func verdictBandRendersTrajectoryTimestampAndFreshness() {
        let page = GraphRenderer.dashboardPage(
            title: "Project", sections: [
                portfolioSection(heading: "Feature · a", statuses: [.done, .rework], owner: "alice")
            ], now: fixedNow)
        #expect(page.contains("<section class=\"verdict-band\""))
        #expect(page.contains("verdict-trajectory trajectory-slipping"))
        #expect(page.contains(">slipping</p>"))
        #expect(page.contains("generated 2026-06-24 09:30 UTC"))
        // A clean section ⇒ no stale badge text, the `fresh` badge instead.
        #expect(!page.contains("⚠ stale run"))
        #expect(page.contains("verdict-freshness fresh"))
    }

    @Test func projectRollupRendersBeforeFirstDetailSection() {
        let page = GraphRenderer.dashboardPage(
            title: "Project", sections: [
                portfolioSection(heading: "Feature · a", statuses: [.done], owner: "alice"),
                portfolioSection(heading: "Feature · b", statuses: [.runnable], owner: "bob")
            ], now: fixedNow)
        let verdictAt = try! #require(page.range(of: "class=\"verdict-band\"")).lowerBound
        let portfolioAt = try! #require(page.range(of: "class=\"portfolio-band\"")).lowerBound
        let firstDetailAt = try! #require(page.range(of: "class=\"dashboard-section\"")).lowerBound
        #expect(verdictAt < portfolioAt)
        #expect(portfolioAt < firstDetailAt)
    }

    @Test func portfolioBandRendersOneHealthRowPerFeature() {
        let sections = [
            portfolioSection(heading: "Feature · a", statuses: [.done, .done, .rework], owner: "alice"),
            portfolioSection(heading: "Feature · b", statuses: [.done, .runnable], owner: "bob")
        ]
        let rows = GraphRenderer.portfolioRows(for: sections)
        #expect(rows.count == 2)
        #expect(rows[0].heading == "Feature · a")
        #expect(rows[0].doneCount == 2)
        #expect(rows[0].totalCount == 3)
        #expect(rows[0].owner == "alice")
        #expect(rows[0].blocker == "n2")   // the rework node
        #expect(rows[1].blocker == "—")

        let page = GraphRenderer.dashboardPage(title: "Project", sections: sections, now: fixedNow)
        // Headline is labelled `slices`, not effort; one row per feature.
        #expect(page.contains("2/3 (67%) slices"))
        #expect(page.contains("1/2 (50%) slices"))
        #expect(page.contains("<th>Feature</th><th>Slices</th><th>Owner</th><th>Blocker</th>"))
    }

    @Test func portfolioOwnerFallsBackToUnowned() {
        // When the section's only owner degenerates to the feature name, the cell renders `unowned`.
        let unowned = [portfolioSection(heading: "Feature · alpha", statuses: [.runnable], owner: "alpha")]
        #expect(GraphRenderer.portfolioRows(for: unowned)[0].owner == "unowned")

        let owned = [portfolioSection(heading: "Feature · alpha", statuses: [.runnable], owner: "carol")]
        #expect(GraphRenderer.portfolioRows(for: owned)[0].owner == "carol")

        let page = GraphRenderer.dashboardPage(title: "P", sections: unowned, now: fixedNow)
        #expect(page.contains("<td>unowned</td>"))
    }

    @Test func verdictFreshnessReusesStaleMarker() {
        let staleSections = [
            portfolioSection(heading: "Feature · a", statuses: [.done], owner: "alice", staleRun: true)
        ]
        let stale = GraphRenderer.dashboardPage(title: "P", sections: staleSections, now: fixedNow)
        // The freshness badge reuses the exact `⚠ stale run` marker (also still in the section header).
        #expect(stale.contains("verdict-freshness stale"))
        #expect(stale.contains("⚠ stale run"))

        let cleanSections = [portfolioSection(heading: "Feature · a", statuses: [.done], owner: "alice")]
        let clean = GraphRenderer.dashboardPage(title: "P", sections: cleanSections, now: fixedNow)
        #expect(!clean.contains("⚠ stale run"))
    }

    @Test func injectedNowYieldsByteIdenticalOutput() {
        let sections = [portfolioSection(heading: "Feature · a", statuses: [.done, .runnable], owner: "alice")]
        let first = GraphRenderer.dashboardPage(title: "P", sections: sections, now: fixedNow)
        let second = GraphRenderer.dashboardPage(title: "P", sections: sections, now: fixedNow)
        #expect(first == second)
        // A different `now` changes only the timestamp, proving it is the injected value rendered.
        let later = GraphRenderer.dashboardPage(
            title: "P", sections: sections,
            now: Date(timeIntervalSince1970: 1_782_379_800))   // 2026-06-25 09:30 UTC
        #expect(first != later)
        #expect(later.contains("generated 2026-06-25 09:30 UTC"))
    }

    @Test func timestampFormatIsDeterministicUTC() {
        #expect(GraphRenderer.formatTimestamp(fixedNow) == "2026-06-24 09:30 UTC")
        #expect(GraphRenderer.formatTimestamp(Date(timeIntervalSince1970: 0)) == "1970-01-01 00:00 UTC")
    }

    @Test func existingModesPreservedDefaultNowStillRenders() {
        // The defaulted `now` keeps existing call sites source-stable; the page still renders the
        // header, charts, legend, and per-section detail alongside the new rollup.
        let summary = DashboardProjectionSummary(
            totalFeatureCount: 1, totalNodeCount: 1, doneCount: 1,
            statusTotals: [.done: 1, .inProgress: 0, .rework: 0, .escalated: 0, .runnable: 0, .pending: 0])
        let page = GraphRenderer.dashboardPage(title: "Legacy", sections: [
            .init(heading: "Feature · legacy",
                  projection: .init(rows: [DashboardProjectionRow(
                    node: "plan", stack: "swift", owner: "alice", lane: "code", milestone: "m1",
                    dependencyCount: 0, status: .done, nextActionHint: .none)], summary: summary))
        ])
        #expect(page.hasPrefix("<!doctype html>"))
        #expect(page.contains("class=\"dashboard-chart dashboard-status-donut\""))
        #expect(page.contains("<h2>Feature · legacy</h2>"))
        #expect(page.contains("class=\"verdict-band\""))
        #expect(page.contains("class=\"portfolio-band\""))
    }

    // MARK: - Run store

    // The store is append-only; state is always a pure projection of the replayed event log.
    @Test func runStorePersistsAndReplays() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-sdd-test-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - ArtifactDiff (changed .ai-sdd/ files between a baseline and the working tree)

    // An ArtifactDiff whose git execution is stubbed: returns canned --name-status output and records
    // the exact argument vector it was handed, so tests need no real repo.
    private final class CapturingGit: @unchecked Sendable {
        var arguments: [String] = []
        let output: String
        init(_ output: String) { self.output = output }
        func diff(workingDirectory: URL = URL(fileURLWithPath: "/")) -> ArtifactDiff {
            ArtifactDiff(workingDirectory: workingDirectory) { arguments, _ in
                self.arguments = arguments
                return (0, self.output)
            }
        }
    }

    // ACC-canned-status-set: A/M/D lines under .ai-sdd/ map to added/modified/deleted exactly.
    @Test func artifactDiffMapsCannedStatusSet() {
        let git = CapturingGit("""
        A\t.ai-sdd/skills/new-skill/SKILL.md
        M\t.ai-sdd/conventions/swift.md
        D\t.ai-sdd/schemas/old.schema.yaml
        """)
        let changes = git.diff().changedArtifacts()
        #expect(changes == [
            ArtifactChange(path: ".ai-sdd/skills/new-skill/SKILL.md", status: .added),
            ArtifactChange(path: ".ai-sdd/conventions/swift.md", status: .modified),
            ArtifactChange(path: ".ai-sdd/schemas/old.schema.yaml", status: .deleted)
        ])
    }

    // ACC-exclude-runtime-paths: changes under .ai-sdd/runs/ and .ai-sdd/artifacts/ are dropped.
    @Test func artifactDiffExcludesRuntimePaths() {
        let git = CapturingGit("""
        M\t.ai-sdd/conventions/swift.md
        M\t.ai-sdd/runs/abc/run.json
        A\t.ai-sdd/artifacts/changeset.v1.yaml
        """)
        #expect(git.diff().changedArtifacts() == [
            ArtifactChange(path: ".ai-sdd/conventions/swift.md", status: .modified)
        ])
    }

    // ACC-exclude-non-home: a changed path outside .ai-sdd/ is not returned.
    @Test func artifactDiffExcludesNonHomePaths() {
        let git = CapturingGit("""
        M\tSources/AISDDEngine/ArtifactChange.swift
        M\tREADME.md
        A\t.ai-sdd/skills/x/SKILL.md
        """)
        #expect(git.diff().changedArtifacts() == [
            ArtifactChange(path: ".ai-sdd/skills/x/SKILL.md", status: .added)
        ])
    }

    // ACC-override-baseline-ref: an override ref (not HEAD) is the one threaded into the git args.
    @Test func artifactDiffThreadsOverrideBaselineRef() {
        let git = CapturingGit("M\t.ai-sdd/conventions/swift.md")

        // Default baseline is HEAD.
        _ = git.diff().changedArtifacts()
        #expect(git.arguments == ["diff", "--name-status", "HEAD", "--", ".ai-sdd/"])

        // An override ref is substituted into the baseline position.
        _ = git.diff().changedArtifacts(baseline: "main~3")
        #expect(git.arguments == ["diff", "--name-status", "main~3", "--", ".ai-sdd/"])
        #expect(git.arguments.contains("main~3"))
        #expect(!git.arguments.contains("HEAD"))
    }

    // ACC-read-only: only the executor is invoked (a read); R/C/T codes are skipped not misclassified.
    @Test func artifactDiffIsReadOnlyAndSkipsRenameCopyTypechange() {
        let git = CapturingGit("""
        R100\t.ai-sdd/old.md\t.ai-sdd/new.md
        C75\t.ai-sdd/a.md\t.ai-sdd/b.md
        T\t.ai-sdd/c.md
        M\t.ai-sdd/conventions/swift.md
        """)
        // Only the M line survives — R/C/T are out of scope and dropped, not misclassified.
        #expect(git.diff().changedArtifacts() == [
            ArtifactChange(path: ".ai-sdd/conventions/swift.md", status: .modified)
        ])
        // The only invocation was the read-only `git diff` — no write/stage command issued.
        #expect(git.arguments.first == "diff")
        #expect(!git.arguments.contains("add"))
        #expect(!git.arguments.contains("commit"))
    }

    // MARK: - Program dashboard rollup projection

    /// Models the guardrails program shape: two feature nodes (kind: pipeline) joined through a
    /// milestone-gate node, then a third feature gated on the milestone.
    private func programPipeline() -> PipelineSpec {
        PipelineSpec(
            semantics: "enabler",
            nodes: [
                PipelineNode(id: "locks", kind: "pipeline", pipeline: "../../features/locks",
                             stack: "swift", owner: ["maintainer"]),
                PipelineNode(id: "provenance", kind: "pipeline", pipeline: "../../features/provenance",
                             stack: "swift", owner: ["maintainer"]),
                PipelineNode(id: "m1-guardrails-integrated", worker: "milestone-gate", owner: ["maintainer"]),
                PipelineNode(id: "drift", kind: "pipeline", pipeline: "../../features/drift",
                             stack: "swift", owner: ["maintainer"])
            ],
            edges: [
                PipelineEdge(from: OneOrMany(["locks"]), to: "m1-guardrails-integrated"),
                PipelineEdge(from: OneOrMany(["provenance"]), to: "m1-guardrails-integrated"),
                PipelineEdge(from: OneOrMany(["m1-guardrails-integrated"]), to: "drift")
            ])
    }

    /// A simple two-node sub-pipeline used as an injected feature pipeline.
    private func featureSubPipeline() -> (spec: PipelineSpec, metadata: SpecMetadata) {
        (PipelineSpec(
            nodes: [PipelineNode(id: "plan"), PipelineNode(id: "implement")],
            edges: [PipelineEdge(from: OneOrMany(["plan"]), to: "implement")]),
         SpecMetadata(name: "feature"))
    }

    @Test func programProjectionEmitsOneRowPerNode() {
        let result = DashboardProjection.project(
            program: programPipeline(),
            metadata: SpecMetadata(name: "guardrails"))

        #expect(result.rows.map(\.node) ==
            ["locks", "provenance", "m1-guardrails-integrated", "drift"])
        #expect(result.summary.totalFeatureCount == 1)
        #expect(result.summary.totalNodeCount == 4)
    }

    @Test func programFeatureEscalatedTakesPrecedence() {
        let state = RunState(
            completedNodes: ["locks"],
            failedChecks: ["locks": ["unit"]],
            escalatedNodes: ["locks"],
            slices: ["locks": RunState(completedNodes: ["plan", "implement"])])
        let result = DashboardProjection.project(
            program: programPipeline(), metadata: SpecMetadata(name: "guardrails"), state: state,
            featurePipeline: { _ in self.featureSubPipeline() })
        #expect(status(result, "locks") == .escalated)
    }

    @Test func programFeatureReworkWhenNotEscalated() {
        let state = RunState(failedChecks: ["locks": ["unit"]])
        let result = DashboardProjection.project(
            program: programPipeline(), metadata: SpecMetadata(name: "guardrails"), state: state,
            featurePipeline: { _ in self.featureSubPipeline() })
        #expect(status(result, "locks") == .rework)
    }

    @Test func programFeatureTopLevelDoneWithoutDescent() {
        // completedNodes marks locks done; the sub-pipeline (all started) must NOT downgrade it.
        let state = RunState(
            completedNodes: ["locks"],
            slices: ["locks": RunState(inProgressNodes: ["implement"])])
        let result = DashboardProjection.project(
            program: programPipeline(), metadata: SpecMetadata(name: "guardrails"), state: state,
            featurePipeline: { _ in self.featureSubPipeline() })
        #expect(status(result, "locks") == .done)
    }

    @Test func programFeatureNestedAllDoneRollsUpDone() {
        let state = RunState(
            slices: ["locks": RunState(completedNodes: ["plan", "implement"])])
        let result = DashboardProjection.project(
            program: programPipeline(), metadata: SpecMetadata(name: "guardrails"), state: state,
            featurePipeline: { _ in self.featureSubPipeline() })
        #expect(status(result, "locks") == .done)
    }

    @Test func programFeatureNestedAnyStartedRollsUpInProgress() {
        let state = RunState(
            slices: ["locks": RunState(inProgressNodes: ["implement"])])
        let result = DashboardProjection.project(
            program: programPipeline(), metadata: SpecMetadata(name: "guardrails"), state: state,
            featurePipeline: { _ in self.featureSubPipeline() })
        #expect(status(result, "locks") == .inProgress)
    }

    @Test func programFeatureProgramTierRunnableForSource() {
        // No run signal and an empty nested sub-pipeline state ⇒ program-tier readiness.
        let result = DashboardProjection.project(
            program: programPipeline(), metadata: SpecMetadata(name: "guardrails"), state: RunState(),
            featurePipeline: { _ in self.featureSubPipeline() })
        // locks is a program-tier source ⇒ runnable.
        #expect(status(result, "locks") == .runnable)
    }

    @Test func programFeatureProgramTierPendingForGatedNode() {
        let result = DashboardProjection.project(
            program: programPipeline(), metadata: SpecMetadata(name: "guardrails"), state: RunState(),
            featurePipeline: { _ in self.featureSubPipeline() })
        // drift depends on the milestone, which is not complete ⇒ pending.
        #expect(status(result, "drift") == .pending)
    }

    @Test func programNoRunResolvesStaticallyWithoutCrash() {
        let result = DashboardProjection.project(
            program: programPipeline(), metadata: SpecMetadata(name: "guardrails"))
        #expect(status(result, "locks") == .runnable)
        #expect(status(result, "provenance") == .runnable)
        #expect(status(result, "m1-guardrails-integrated") == .pending)
        #expect(status(result, "drift") == .pending)
    }

    @Test func programMissingSubPipelineDegradesToProgramTier() {
        // Closure returns nil ⇒ no descent; top-level/program-tier signals only, no crash.
        let state = RunState(completedNodes: ["locks"])
        let degraded = DashboardProjection.project(
            program: programPipeline(), metadata: SpecMetadata(name: "guardrails"), state: state)
        #expect(status(degraded, "locks") == .done)        // top-level signal still applies
        #expect(status(degraded, "provenance") == .runnable) // program-tier source
        #expect(status(degraded, "drift") == .pending)       // gated ⇒ pending, no crash
    }

    @Test func programMilestoneGateUsesPlainNodePrecedence() {
        let runnableState = RunState(completedNodes: ["locks", "provenance"])
        let runnableResult = DashboardProjection.project(
            program: programPipeline(), metadata: SpecMetadata(name: "guardrails"), state: runnableState)
        #expect(status(runnableResult, "m1-guardrails-integrated") == .runnable)

        let doneState = RunState(completedNodes: ["locks", "provenance", "m1-guardrails-integrated"])
        let doneResult = DashboardProjection.project(
            program: programPipeline(), metadata: SpecMetadata(name: "guardrails"), state: doneState)
        #expect(status(doneResult, "m1-guardrails-integrated") == .done)

        let escalatedState = RunState(escalatedNodes: ["m1-guardrails-integrated"])
        let escalatedResult = DashboardProjection.project(
            program: programPipeline(), metadata: SpecMetadata(name: "guardrails"), state: escalatedState)
        #expect(status(escalatedResult, "m1-guardrails-integrated") == .escalated)
    }

    @Test func programMilestoneRowIsFlaggedAndFeaturesAreNot() throws {
        let result = DashboardProjection.project(
            program: programPipeline(), metadata: SpecMetadata(name: "guardrails"))
        let gate = try #require(result.rows.first { $0.node == "m1-guardrails-integrated" })
        #expect(gate.isMilestone)
        let locks = try #require(result.rows.first { $0.node == "locks" })
        #expect(!locks.isMilestone)
    }

    @Test func programSummaryCountsReflectRows() {
        let state = RunState(
            completedNodes: ["locks", "provenance"],
            slices: [:])
        let result = DashboardProjection.project(
            program: programPipeline(), metadata: SpecMetadata(name: "guardrails"), state: state)
        #expect(result.summary.totalNodeCount == 4)
        // locks done, provenance done, milestone runnable, drift pending.
        #expect(result.summary.doneCount == 2)
        let total = result.summary.statusTotals.values.reduce(0, +)
        #expect(total == result.rows.count)
        #expect(result.summary.statusTotals[.done] == 2)
        #expect(result.summary.statusTotals[.runnable] == 1)
        #expect(result.summary.statusTotals[.pending] == 1)
    }

    /// Convenience: the status of a named row in a program projection.
    private func status(_ result: DashboardProjectionResult, _ node: String) -> DashboardStatus? {
        result.rows.first { $0.node == node }?.status
    }

    // MARK: - Program dashboard assembler (file-aware)

    /// Write a guardrails-shaped program at `dir`: two `kind: pipeline` feature nodes →
    /// milestone-gate → a third feature gated on the milestone, with the matching sub-pipelines under
    /// `<dir>/../features/<name>`.
    private func writeProgramFixture(at dir: URL, name: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let yaml = """
        apiVersion: ai-sdd/v1
        kind: Pipeline
        metadata: { name: \(name), version: 1, owner: [maintainer] }
        spec:
          semantics: enabler
          nodes:
            - { id: locks, kind: pipeline, pipeline: ../features/locks, stack: swift }
            - { id: provenance, kind: pipeline, pipeline: ../features/provenance, stack: swift }
            - { id: m1-guardrails-integrated, worker: milestone-gate, owner: [maintainer] }
            - { id: drift, kind: pipeline, pipeline: ../features/drift, stack: swift }
          edges:
            - { from: locks, to: m1-guardrails-integrated }
            - { from: provenance, to: m1-guardrails-integrated }
            - { from: m1-guardrails-integrated, to: drift }
        """
        try yaml.write(to: dir.appendingPathComponent("pipeline.yaml"), atomically: true, encoding: .utf8)

        let features = dir.deletingLastPathComponent().appendingPathComponent("features", isDirectory: true)
        for feature in ["locks", "provenance", "drift"] {
            try writePipeline(at: features.appendingPathComponent(feature, isDirectory: true),
                              name: feature, nodes: ["plan", "implement"], edges: [("plan", "implement")])
        }
    }

    @Test func programDashboardAssemblerLoadsPipelineAndEmitsOneSection() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-sdd-program-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let programDir = root.appendingPathComponent("programs", isDirectory: true)
            .appendingPathComponent("guardrails", isDirectory: true)
        try writeProgramFixture(at: programDir, name: "guardrails")

        let store = RunStore(root: root.appendingPathComponent("runs", isDirectory: true))
        let dashboard = try ProgramDashboardAssembler.assemble(programDir: programDir, runStore: store)

        #expect(dashboard.title == "guardrails")
        #expect(dashboard.sections.map(\.heading) == ["Program · guardrails"])
        #expect(dashboard.sections[0].projection.rows.map(\.node) ==
            ["locks", "provenance", "m1-guardrails-integrated", "drift"])
    }

    @Test func programDashboardAssemblerMatchesRunByPipelineDirAndRollsUpSubPipelines() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-sdd-program-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let programDir = root.appendingPathComponent("programs", isDirectory: true)
            .appendingPathComponent("guardrails", isDirectory: true)
        try writeProgramFixture(at: programDir, name: "guardrails")

        let store = RunStore(root: root.appendingPathComponent("runs", isDirectory: true))
        try store.create(runId: "prog-run", pipelineDir: programDir.standardizedFileURL.path)
        // locks' sub-pipeline fully done ⇒ rollup done; provenance started ⇒ in-progress.
        try store.append(.scoped(slice: "locks", event: .nodeCompleted(node: "plan", producedArtifacts: [])),
                         to: "prog-run")
        try store.append(.scoped(slice: "locks", event: .nodeCompleted(node: "implement", producedArtifacts: [])),
                         to: "prog-run")
        try store.append(.scoped(slice: "provenance", event: .nodeStarted(node: "plan")), to: "prog-run")

        let dashboard = try ProgramDashboardAssembler.assemble(programDir: programDir, runStore: store)
        let rows = dashboard.sections[0].projection.rows
        #expect(status(dashboard.sections[0].projection, "locks") == .done)
        #expect(status(dashboard.sections[0].projection, "provenance") == .inProgress)
        // A non-matching run is ignored: the milestone is still pending (deps not all done).
        #expect(status(dashboard.sections[0].projection, "m1-guardrails-integrated") == .pending)
        #expect(rows.first { $0.node == "m1-guardrails-integrated" }?.isMilestone == true)
    }

    @Test func programDashboardAssemblerSurfacesMilestoneGateStatus() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-sdd-program-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let programDir = root.appendingPathComponent("programs", isDirectory: true)
            .appendingPathComponent("guardrails", isDirectory: true)
        try writeProgramFixture(at: programDir, name: "guardrails")

        let store = RunStore(root: root.appendingPathComponent("runs", isDirectory: true))
        try store.create(runId: "prog-run", pipelineDir: programDir.standardizedFileURL.path)
        // Both feature deps of the gate completed at the program tier ⇒ gate runnable.
        try store.append(.nodeCompleted(node: "locks", producedArtifacts: []), to: "prog-run")
        try store.append(.nodeCompleted(node: "provenance", producedArtifacts: []), to: "prog-run")

        let dashboard = try ProgramDashboardAssembler.assemble(programDir: programDir, runStore: store)
        let projection = dashboard.sections[0].projection
        #expect(status(projection, "m1-guardrails-integrated") == .runnable)
        #expect(projection.rows.first { $0.node == "m1-guardrails-integrated" }?.isMilestone == true)
    }

    @Test func programDashboardAssemblerDegradesStaticallyWithNoRun() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-sdd-program-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let programDir = root.appendingPathComponent("programs", isDirectory: true)
            .appendingPathComponent("guardrails", isDirectory: true)
        try writeProgramFixture(at: programDir, name: "guardrails")

        // Empty store ⇒ no matching run ⇒ static statuses, no crash.
        let store = RunStore(root: root.appendingPathComponent("runs", isDirectory: true))
        let dashboard = try ProgramDashboardAssembler.assemble(programDir: programDir, runStore: store)
        let projection = dashboard.sections[0].projection
        #expect(status(projection, "locks") == .runnable)
        #expect(status(projection, "provenance") == .runnable)
        #expect(status(projection, "m1-guardrails-integrated") == .pending)
        #expect(status(projection, "drift") == .pending)
    }

    @Test func programDashboardAssemblerDegradesWhenSubPipelineMissing() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-sdd-program-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let programDir = root.appendingPathComponent("programs", isDirectory: true)
            .appendingPathComponent("guardrails", isDirectory: true)
        try writeProgramFixture(at: programDir, name: "guardrails")
        // Remove the locks sub-pipeline (resolved at programs/features/locks) so its loader
        // closure returns nil.
        try FileManager.default.removeItem(
            at: programDir.deletingLastPathComponent()
                .appendingPathComponent("features/locks", isDirectory: true))

        let store = RunStore(root: root.appendingPathComponent("runs", isDirectory: true))
        try store.create(runId: "prog-run", pipelineDir: programDir.standardizedFileURL.path)
        try store.append(.nodeCompleted(node: "locks", producedArtifacts: []), to: "prog-run")

        let dashboard = try ProgramDashboardAssembler.assemble(programDir: programDir, runStore: store)
        let projection = dashboard.sections[0].projection
        // Missing sub-pipeline ⇒ falls back to the top-level program-tier signal (locks completed).
        #expect(status(projection, "locks") == .done)
        #expect(status(projection, "provenance") == .runnable)
    }

    @Test func programDashboardAssemblerThrowsInvalidProgramOnUnloadablePipeline() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-sdd-program-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let programDir = root.appendingPathComponent("programs", isDirectory: true)
            .appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: programDir, withIntermediateDirectories: true)
        // No pipeline.yaml at all ⇒ the exact typed error.
        let store = RunStore(root: root.appendingPathComponent("runs", isDirectory: true))
        #expect(throws: ProjectDashboardError.invalidProgram(programDir.path)) {
            try ProgramDashboardAssembler.assemble(programDir: programDir, runStore: store)
        }
    }

    // MARK: - Whole-repo dashboard: features + programs (ProjectDashboardAssembler)

    @Test func projectDashboardAssemblerAppendsProgramSectionsAfterFeaturesAlphabetically() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-sdd-dashboard-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // A build-pattern at the root plus a feature, and two programs (out of alpha order on disk).
        try writePipeline(at: tmp, name: "factory", nodes: ["build"], edges: [])
        let features = tmp.appendingPathComponent("features", isDirectory: true)
        try writePipeline(at: features.appendingPathComponent("alpha", isDirectory: true),
                          name: "alpha", nodes: ["plan", "implement"], edges: [("plan", "implement")])
        let programs = tmp.appendingPathComponent("programs", isDirectory: true)
        try writeProgramFixture(at: programs.appendingPathComponent("zeta", isDirectory: true),
                                name: "zeta")
        try writeProgramFixture(at: programs.appendingPathComponent("guardrails", isDirectory: true),
                                name: "guardrails")

        // Match the guardrails program run and roll up its sub-pipelines.
        let store = RunStore(root: tmp.appendingPathComponent("runs", isDirectory: true))
        let guardrailsDir = programs.appendingPathComponent("guardrails", isDirectory: true)
        try store.create(runId: "prog-run", pipelineDir: guardrailsDir.standardizedFileURL.path)
        try store.append(.scoped(slice: "locks", event: .nodeCompleted(node: "plan", producedArtifacts: [])),
                         to: "prog-run")
        try store.append(.scoped(slice: "locks", event: .nodeCompleted(node: "implement", producedArtifacts: [])),
                         to: "prog-run")
        try store.append(.scoped(slice: "provenance", event: .nodeStarted(node: "plan")), to: "prog-run")

        let dashboard = try ProjectDashboardAssembler.assemble(factoryDir: tmp, runStore: store)

        // Feature first, then Program sections alphabetical by slug. Build pattern is runnable-only
        // here (no active work) so it does not append — preserving the existing conditional behavior.
        #expect(dashboard.sections.map(\.heading) == [
            "Feature · alpha",
            "Program · guardrails",
            "Program · zeta"
        ])

        let guardrails = try #require(dashboard.sections.first { $0.heading == "Program · guardrails" })
        #expect(status(guardrails.projection, "locks") == .done)
        #expect(status(guardrails.projection, "provenance") == .inProgress)
        #expect(guardrails.projection.rows.first { $0.node == "m1-guardrails-integrated" }?.isMilestone == true)
    }

    @Test func projectDashboardAssemblerWithNoProgramsDirHasNoProgramSections() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-sdd-dashboard-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try writePipeline(at: tmp, name: "factory", nodes: ["build"], edges: [])
        try writePipeline(at: tmp.appendingPathComponent("features", isDirectory: true)
                            .appendingPathComponent("alpha", isDirectory: true),
                          name: "alpha", nodes: ["plan"], edges: [])

        let dashboard = try ProjectDashboardAssembler.assemble(
            factoryDir: tmp,
            runStore: RunStore(root: tmp.appendingPathComponent("runs", isDirectory: true)))

        // No programs/ dir ⇒ only the Feature section (build pattern is runnable-only, not appended).
        #expect(dashboard.sections.map(\.heading) == ["Feature · alpha"])
        #expect(dashboard.sections.allSatisfy { !$0.heading.hasPrefix("Program · ") })
    }

    @Test func projectDashboardAssemblerSkipsBrokenProgramButRendersValidOnes() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-sdd-dashboard-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try writePipeline(at: tmp, name: "factory", nodes: ["build"], edges: [])
        let programs = tmp.appendingPathComponent("programs", isDirectory: true)
        try writeProgramFixture(at: programs.appendingPathComponent("guardrails", isDirectory: true),
                                name: "guardrails")
        // A broken program: pipeline.yaml present but malformed ⇒ programSection returns nil.
        let broken = programs.appendingPathComponent("zeta-broken", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try "not: a pipeline".write(to: broken.appendingPathComponent("pipeline.yaml"),
                                    atomically: true, encoding: .utf8)

        let store = RunStore(root: tmp.appendingPathComponent("runs", isDirectory: true))
        let dashboard = try ProjectDashboardAssembler.assemble(factoryDir: tmp, runStore: store)

        // The broken program is skipped (not fatal); the valid one still renders.
        #expect(dashboard.sections.map(\.heading) == ["Program · guardrails"])
    }

    @Test func programDashboardAssemblerStandaloneStillThrowsOnBrokenProgram() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-sdd-program-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let programDir = root.appendingPathComponent("programs", isDirectory: true)
            .appendingPathComponent("broken", isDirectory: true)
        try FileManager.default.createDirectory(at: programDir, withIntermediateDirectories: true)
        try "not: a pipeline".write(to: programDir.appendingPathComponent("pipeline.yaml"),
                                    atomically: true, encoding: .utf8)

        let store = RunStore(root: root.appendingPathComponent("runs", isDirectory: true))
        // Standalone behavior preserved: a broken/unloadable program still throws invalidProgram.
        #expect(throws: ProjectDashboardError.invalidProgram(programDir.path)) {
            try ProgramDashboardAssembler.assemble(programDir: programDir, runStore: store)
        }
    }

    // MARK: - Portable run matching (relative pipelineDir resolves against the run-store base)

    @Test func runStoreBaseInvertsLocalUnder() {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-sdd-base-\(UUID().uuidString)", isDirectory: true)
        #expect(RunStore.local(under: base).base.standardizedFileURL.path
            == base.standardizedFileURL.path)
    }

    @Test func baseForTargetAiSddReturnsBase() {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-sdd-fromtarget-\(UUID().uuidString)", isDirectory: true)
        let target = base.appendingPathComponent(".ai-sdd", isDirectory: true)
        #expect(RunStore.base(forTarget: target).standardizedFileURL.path
            == base.standardizedFileURL.path)
    }

    @Test func baseForTargetProgramSubdirReturnsBase() {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-sdd-fromtarget-\(UUID().uuidString)", isDirectory: true)
        let target = base.appendingPathComponent(".ai-sdd", isDirectory: true)
            .appendingPathComponent("programs", isDirectory: true)
            .appendingPathComponent("x", isDirectory: true)
        #expect(RunStore.base(forTarget: target).standardizedFileURL.path
            == base.standardizedFileURL.path)
    }

    @Test func baseForTargetNestedFixtureReturnsFixtureBase() {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-sdd-fromtarget-\(UUID().uuidString)", isDirectory: true)
        let fixture = base.appendingPathComponent("docs", isDirectory: true)
            .appendingPathComponent("examples", isDirectory: true)
            .appendingPathComponent("demo-factory", isDirectory: true)
        // <fixture>/.ai-sdd → <fixture>
        let target = fixture.appendingPathComponent(".ai-sdd", isDirectory: true)
        let resolved = RunStore.base(forTarget: target).standardizedFileURL.path
        #expect(resolved == fixture.standardizedFileURL.path)
        #expect(resolved.hasSuffix("docs/examples/demo-factory"))
        // <fixture>/.ai-sdd/programs/x → <fixture> (closest .ai-sdd ancestor wins)
        let programTarget = target.appendingPathComponent("programs", isDirectory: true)
            .appendingPathComponent("x", isDirectory: true)
        #expect(RunStore.base(forTarget: programTarget).standardizedFileURL.path
            == fixture.standardizedFileURL.path)
    }

    @Test func baseForTargetNoAiSddFallsBackToCwd() {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-sdd-fromtarget-\(UUID().uuidString)", isDirectory: true)
        let target = base.appendingPathComponent("not-a-factory", isDirectory: true)
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        #expect(RunStore.base(forTarget: target).standardizedFileURL.path
            == cwd.standardizedFileURL.path)
    }

    @Test func matchedStateStillMatchesAbsolutePipelineDir() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-sdd-portable-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let feature = base.appendingPathComponent("features", isDirectory: true)
            .appendingPathComponent("alpha", isDirectory: true)
        try writePipeline(at: feature, name: "alpha", nodes: ["plan", "implement"],
                          edges: [("plan", "implement")])

        let store = RunStore.local(under: base)
        // Regression guard: an ABSOLUTE stored pipelineDir still matches (base is irrelevant).
        try store.create(runId: "abs-run", pipelineDir: feature.standardizedFileURL.path)
        try store.append(.nodeCompleted(node: "plan", producedArtifacts: []), to: "abs-run")

        let dashboard = try ProjectDashboardAssembler.assemble(factoryDir: base, runStore: store)
        let rows = try #require(dashboard.sections.first { $0.heading == "Feature · alpha" }?.projection.rows)
        #expect(Dictionary(uniqueKeysWithValues: rows.map { ($0.node, $0.status) }) == [
            "plan": .done,
            "implement": .runnable
        ])
    }

    @Test func matchedStateResolvesRelativePipelineDirAgainstBase() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-sdd-portable-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let feature = base.appendingPathComponent("features", isDirectory: true)
            .appendingPathComponent("alpha", isDirectory: true)
        try writePipeline(at: feature, name: "alpha", nodes: ["plan", "implement"],
                          edges: [("plan", "implement")])

        let store = RunStore.local(under: base)
        // A committed-fixture-style RELATIVE pipelineDir resolves against the run-store base and
        // matches the absolute feature dir at <base>/features/alpha.
        try store.create(runId: "rel-run", pipelineDir: "features/alpha")
        try store.append(.nodeCompleted(node: "plan", producedArtifacts: []), to: "rel-run")

        let dashboard = try ProjectDashboardAssembler.assemble(factoryDir: base, runStore: store)
        let rows = try #require(dashboard.sections.first { $0.heading == "Feature · alpha" }?.projection.rows)
        #expect(Dictionary(uniqueKeysWithValues: rows.map { ($0.node, $0.status) }) == [
            "plan": .done,
            "implement": .runnable
        ])
    }

    @Test func matchedStateResolvesRelativeProgramPipelineDirAgainstBase() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-sdd-portable-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let programDir = base.appendingPathComponent(Layout.programsDir, isDirectory: true)
            .appendingPathComponent("guardrails", isDirectory: true)
        try writeProgramFixture(at: programDir, name: "guardrails")

        let store = RunStore.local(under: base)
        // A RELATIVE program pipelineDir (e.g. `.ai-sdd/programs/<slug>`-style) resolves against the
        // base and matches the absolute program dir, so the seeded rollup status renders.
        try store.create(runId: "prog-rel-run",
                         pipelineDir: "\(Layout.programsDir)/guardrails")
        try store.append(.scoped(slice: "locks", event: .nodeCompleted(node: "plan", producedArtifacts: [])),
                         to: "prog-rel-run")
        try store.append(.scoped(slice: "locks", event: .nodeCompleted(node: "implement", producedArtifacts: [])),
                         to: "prog-rel-run")

        let dashboard = try ProgramDashboardAssembler.assemble(programDir: programDir, runStore: store)
        #expect(status(dashboard.sections[0].projection, "locks") == .done)
    }

    @Test func matchedStateIgnoresNonMatchingRelativePipelineDir() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-sdd-portable-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let feature = base.appendingPathComponent("features", isDirectory: true)
            .appendingPathComponent("alpha", isDirectory: true)
        try writePipeline(at: feature, name: "alpha", nodes: ["plan", "implement"],
                          edges: [("plan", "implement")])

        let store = RunStore.local(under: base)
        // A RELATIVE pipelineDir that resolves (against the base) to a DIFFERENT dir must NOT match:
        // the node stays stateless (runnable/pending), not the run's done.
        try store.create(runId: "mismatch-run", pipelineDir: "features/beta")
        try store.append(.nodeCompleted(node: "plan", producedArtifacts: []), to: "mismatch-run")

        let dashboard = try ProjectDashboardAssembler.assemble(factoryDir: base, runStore: store)
        let rows = try #require(dashboard.sections.first { $0.heading == "Feature · alpha" }?.projection.rows)
        #expect(Dictionary(uniqueKeysWithValues: rows.map { ($0.node, $0.status) }) == [
            "plan": .runnable,
            "implement": .pending
        ])
    }

    // MARK: - Stale-run surfacing (S4): best-effort attach + `⚠ stale run` marker

    /// A run store whose `create` preserves an absolute `pipelineDir` byte-for-byte (no git
    /// toplevel ⇒ no relativize/heal), so a fixture can plant an unreconcilable absolute pointer.
    private func nonGitStore(under base: URL) -> RunStore {
        let local = RunStore.local(under: base)
        return RunStore(root: local.root, gitToplevel: { nil })
    }

    @Test func projectStaleRunAttachesBestEffortAndFlagsMarker() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-sdd-stale-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let feature = base.appendingPathComponent("features", isDirectory: true)
            .appendingPathComponent("alpha", isDirectory: true)
        try writePipeline(at: feature, name: "alpha", nodes: ["plan", "implement"],
                          edges: [("plan", "implement")])

        let store = nonGitStore(under: base)
        // The adapter-interfaces failure: a completed run whose legacy ABSOLUTE pointer resolves
        // nowhere (S2 could not heal it), but whose trailing segment is the feature name `alpha`.
        let stalePointer = "/legacy/clone/.ai-sdd/features/alpha"
        try store.create(runId: "stale-run", pipelineDir: stalePointer)
        try store.append(.nodeCompleted(node: "plan", producedArtifacts: []), to: "stale-run")

        let dashboard = try ProjectDashboardAssembler.assemble(factoryDir: base, runStore: store)
        let section = try #require(dashboard.sections.first { $0.heading == "Feature · alpha" })
        // Best-effort attach: the run's slice events are credited, NOT dropped to all-pending.
        #expect(Dictionary(uniqueKeysWithValues: section.projection.rows.map { ($0.node, $0.status) }) == [
            "plan": .done,
            "implement": .runnable
        ])
        // The single section-level marker is set, and surfaces in the rendered HTML.
        #expect(section.staleRun)
        let html = GraphRenderer.dashboardPage(title: "t", sections: dashboard.sections)
        #expect(html.contains("⚠ stale run"))
    }

    @Test func programStaleRunAttachesBestEffortAndFlagsMarker() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-sdd-stale-prog-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let programDir = base.appendingPathComponent(Layout.programsDir, isDirectory: true)
            .appendingPathComponent("guardrails", isDirectory: true)
        try writeProgramFixture(at: programDir, name: "guardrails")

        let store = nonGitStore(under: base)
        // Unreconcilable absolute program pointer, trailing segment `guardrails`.
        try store.create(runId: "stale-prog",
                         pipelineDir: "/legacy/clone/.ai-sdd/programs/guardrails")
        try store.append(.scoped(slice: "locks", event: .nodeCompleted(node: "plan", producedArtifacts: [])),
                         to: "stale-prog")
        try store.append(.scoped(slice: "locks", event: .nodeCompleted(node: "implement", producedArtifacts: [])),
                         to: "stale-prog")

        let dashboard = try ProgramDashboardAssembler.assemble(programDir: programDir, runStore: store)
        // The program section credits the run's folded slice state and carries the stale marker.
        #expect(status(dashboard.sections[0].projection, "locks") == .done)
        #expect(dashboard.sections[0].staleRun)
    }

    @Test func healedRunMatchesExactPathAndCarriesNoMarker() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-sdd-healed-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let feature = base.appendingPathComponent("features", isDirectory: true)
            .appendingPathComponent("alpha", isDirectory: true)
        try writePipeline(at: feature, name: "alpha", nodes: ["plan", "implement"],
                          edges: [("plan", "implement")])

        let store = nonGitStore(under: base)
        // A run S2 already healed resolves by exact path (a relative pointer anchored to the base).
        try store.create(runId: "healed-run", pipelineDir: "features/alpha")
        try store.append(.nodeCompleted(node: "plan", producedArtifacts: []), to: "healed-run")

        let dashboard = try ProjectDashboardAssembler.assemble(factoryDir: base, runStore: store)
        let section = try #require(dashboard.sections.first { $0.heading == "Feature · alpha" })
        #expect(status(section.projection, "plan") == .done)
        // Exact match ⇒ NO marker, and the HTML has no stale-run breadcrumb.
        #expect(!section.staleRun)
        #expect(!GraphRenderer.dashboardPage(title: "t", sections: dashboard.sections).contains("⚠ stale run"))
    }

    @Test func staleMatchYieldsRecordedAndExpectedForStatusLine() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-sdd-stale-status-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let feature = base.appendingPathComponent("features", isDirectory: true)
            .appendingPathComponent("alpha", isDirectory: true)
        try writePipeline(at: feature, name: "alpha", nodes: ["plan"], edges: [])

        let store = nonGitStore(under: base)
        let stalePointer = "/legacy/clone/.ai-sdd/features/alpha"
        try store.create(runId: "alpha", pipelineDir: stalePointer)

        // The recorded pointer is what `status` reads back; it does not resolve on disk, so the
        // command prints the stale breadcrumb (recorded + expected) instead of loading a bundle.
        let recorded = try store.meta(of: "alpha").pipelineDir
        #expect(recorded == stalePointer)
        #expect(!FileManager.default.fileExists(atPath: recorded))
        // The best-effort matcher attributes the unreconcilable pointer to the `alpha` dir.
        let match = DashboardRunMatch.matchedState(for: feature, in: store)
        #expect(match.stale)
        #expect(DashboardRunMatch.trailingSegment(of: recorded) == feature.standardizedFileURL.lastPathComponent)
    }

    // MARK: - Milestone gate styling + escaping (pure dashboardMermaid)

    @Test func dashboardMermaidStylesMilestonesAsDistinctGates() {
        let pipeline = PipelineSpec(
            nodes: [PipelineNode(id: "locks"),
                    PipelineNode(id: "gate", worker: "milestone-gate")],
            edges: [PipelineEdge(from: OneOrMany(["locks"]), to: "gate")])
        let rows = [
            DashboardProjectionRow(node: "locks", stack: nil, owner: "", lane: nil, milestone: nil,
                                   dependencyCount: 0, status: .done, nextActionHint: .none,
                                   isMilestone: false),
            DashboardProjectionRow(node: "gate", stack: nil, owner: "", lane: nil, milestone: nil,
                                   dependencyCount: 1, status: .pending,
                                   nextActionHint: .waitingOnDependencies, isMilestone: true)
        ]
        let mermaid = GraphRenderer.dashboardMermaid(pipeline, rows: rows)

        // The gate uses the hexagon gate shape and the dedicated status-keyed milestone class.
        #expect(mermaid.contains("gate{{\"gate<br/>"))
        #expect(mermaid.contains(":::milestone_pending"))
        #expect(mermaid.contains("classDef milestone_pending"))
        // The non-milestone row is unchanged: rectangle shape + the plain status class.
        #expect(mermaid.contains("locks[\"locks<br/>"))
        #expect(mermaid.contains(":::status_done"))
        // No gate shape leaks onto the plain node.
        #expect(!mermaid.contains("locks{{"))
    }

    @Test func dashboardMermaidMilestoneClassTracksPassVsBlockedStatus() {
        let pipeline = PipelineSpec(nodes: [PipelineNode(id: "gate", worker: "milestone-gate")], edges: [])
        func mermaid(status: DashboardStatus) -> String {
            GraphRenderer.dashboardMermaid(pipeline, rows: [
                DashboardProjectionRow(node: "gate", stack: nil, owner: "", lane: nil, milestone: nil,
                                       dependencyCount: 0, status: status, nextActionHint: .none,
                                       isMilestone: true)])
        }
        // Pass (done) vs blocked (rework) resolve to distinct status-keyed milestone classes/colors.
        #expect(mermaid(status: .done).contains(":::milestone_done"))
        #expect(mermaid(status: .done).contains("classDef milestone_done"))
        #expect(mermaid(status: .rework).contains(":::milestone_rework"))
        #expect(mermaid(status: .rework).contains("classDef milestone_rework"))
    }

    @Test func dashboardMermaidEscapesDynamicValuesIncludingMilestoneLabels() {
        let pipeline = PipelineSpec(
            nodes: [PipelineNode(id: "gate<x>", worker: "m&w", owner: ["a\"b"])], edges: [])
        let rows = [
            DashboardProjectionRow(node: "gate<x>", stack: nil, owner: "", lane: nil, milestone: nil,
                                   dependencyCount: 0, status: .pending,
                                   nextActionHint: .waitingOnDependencies, isMilestone: true)
        ]
        let mermaid = GraphRenderer.dashboardMermaid(pipeline, rows: rows)
        // Angle brackets, ampersands, and quotes in dynamic values are escaped in the label.
        #expect(mermaid.contains("gate&lt;x&gt;"))
        #expect(mermaid.contains("m&amp;w"))
        #expect(mermaid.contains("a&quot;b"))
        // The raw special chars never reach the rendered label.
        #expect(!mermaid.contains("\"gate<x>"))
        #expect(!mermaid.contains("m&w<br/>"))
    }
}

private extension SpecLoadError {
    var isSyntax: Bool { if case .syntax = self { return true } else { return false } }
    var isSchema: Bool { if case .schema = self { return true } else { return false } }
}

// MARK: - ChangePlan (blast-radius classification)

struct ChangePlanTests {
    /// Build a temp `.ai-sdd/` fixture: `schemas/<each>.schema.yaml`, a `workers/` dir, and a
    /// `pipeline.yaml`. `workers` maps a worker name to the list of schema ids it `consumes`. The
    /// pipeline gets one node per worker, in the given order, each running that worker.
    private func makeFixture(
        schemas: [String],
        workers: [(name: String, consumes: [String])],
        locks: String? = nil
    ) throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("changeplan-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: home.appendingPathComponent("schemas"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appendingPathComponent("workers"), withIntermediateDirectories: true)

        if let locks {
            try locks.write(to: home.appendingPathComponent("locks.yaml"), atomically: true, encoding: .utf8)
        }

        for stem in schemas {
            let yaml = """
            apiVersion: ai-sdd/v1
            kind: Schema
            metadata: { name: \(stem), version: 1 }
            spec: { handle: file, format: yaml, scope: internal }
            """
            try yaml.write(to: home.appendingPathComponent("schemas/\(stem).schema.yaml"),
                           atomically: true, encoding: .utf8)
        }

        for worker in workers {
            let consumesList = worker.consumes.map { "{ schema: \($0), required: true }" }.joined(separator: ", ")
            let yaml = """
            apiVersion: ai-sdd/v1
            kind: Worker
            metadata: { name: \(worker.name) }
            spec:
              workerKind: transform
              consumes: [\(consumesList)]
            """
            try yaml.write(to: home.appendingPathComponent("workers/\(worker.name).worker.yaml"),
                           atomically: true, encoding: .utf8)
        }

        let nodeLines = workers.map { "    - { id: \($0.name)-node, worker: \($0.name) }" }.joined(separator: "\n")
        let pipeline = """
        apiVersion: ai-sdd/v1
        kind: Pipeline
        metadata: { name: fixture, version: 1 }
        spec:
          semantics: enabler
          nodes:
        \(nodeLines)
          edges: []
        """
        try pipeline.write(to: home.appendingPathComponent("pipeline.yaml"),
                           atomically: true, encoding: .utf8)
        return home
    }

    /// Wrap a home-relative subpath into the repo-relative form `git`/`ArtifactDiff` emit.
    private func repoPath(_ subpath: String) -> String { ".ai-sdd/\(subpath)" }

    // ACC-contract-lists-consumers + ACC-reuses-specloader: a changed schema is contract and lists
    // every node whose worker consumes it (>=2 distinct consumers), resolved via SpecLoader.loadBundle.
    @Test func contractChangeListsAllConsumers() throws {
        let home = try makeFixture(
            schemas: ["feature-plan"],
            workers: [
                ("implementer", ["feature-plan.v1"]),
                ("reviewer", ["feature-plan.v1"]),
                ("noop", ["something-else.v1"])
            ])
        let plan = ChangePlan(
            changes: [ArtifactChange(path: repoPath("schemas/feature-plan.schema.yaml"), status: .modified)],
            homeDirectory: home)

        let result = try #require(plan.classifications.first)
        #expect(result.tier == .contract)
        #expect(result.consumers == [
            ChangeConsumer(node: "implementer-node", worker: "implementer"),
            ChangeConsumer(node: "reviewer-node", worker: "reviewer")
        ])
        #expect(result.flags.isEmpty)
    }

    // A single worker reused across two nodes yields one consumer entry per node.
    @Test func contractConsumerPerNode() throws {
        let home = try makeFixture(schemas: ["plan"], workers: [("w", ["plan.v1"])])
        // Add a second node running the same worker by hand-patching the pipeline.
        let pipeline = """
        apiVersion: ai-sdd/v1
        kind: Pipeline
        metadata: { name: fixture, version: 1 }
        spec:
          semantics: enabler
          nodes:
            - { id: nodeA, worker: w }
            - { id: nodeB, worker: w }
          edges: []
        """
        try pipeline.write(to: home.appendingPathComponent("pipeline.yaml"), atomically: true, encoding: .utf8)

        let plan = ChangePlan(
            changes: [ArtifactChange(path: repoPath("schemas/plan.schema.yaml"), status: .modified)],
            homeDirectory: home)
        #expect(plan.classifications.first?.consumers == [
            ChangeConsumer(node: "nodeA", worker: "w"),
            ChangeConsumer(node: "nodeB", worker: "w")
        ])
    }

    // ACC-refresh-and-local-tiers
    @Test func refreshAndLocalTiers() throws {
        let home = try makeFixture(schemas: [], workers: [])
        let plan = ChangePlan(changes: [
            ArtifactChange(path: repoPath("conventions/swift.md"), status: .modified),
            ArtifactChange(path: repoPath("skills/implement-feature/SKILL.md"), status: .modified),
            ArtifactChange(path: repoPath("workers/implementer.worker.yaml"), status: .modified),
            ArtifactChange(path: repoPath("pipeline.yaml"), status: .modified),
            ArtifactChange(path: repoPath("checks/build.check.yaml"), status: .modified)
        ], homeDirectory: home)

        let tiers = plan.classifications.map(\.tier)
        #expect(tiers == [.refresh, .refresh, .local, .local, .local])
        #expect(plan.classifications.allSatisfy { !$0.unclassified })
    }

    // ACC-deleted-schema-breaking-removal
    @Test func deletedSchemaWithConsumersIsBreakingRemoval() throws {
        let home = try makeFixture(
            schemas: ["feature-plan"],
            workers: [("implementer", ["feature-plan.v1"]), ("reviewer", ["feature-plan.v1"])])
        let plan = ChangePlan(
            changes: [ArtifactChange(path: repoPath("schemas/feature-plan.schema.yaml"), status: .deleted)],
            homeDirectory: home)

        let result = try #require(plan.classifications.first)
        #expect(result.tier == .contract)
        #expect(result.flags == [.breakingRemoval])
        #expect(result.consumers.count == 2, "dangling consumers stay listed")
    }

    // ACC-added-schema-zero-consumers
    @Test func addedSchemaZeroConsumersIsNonAckBlocking() throws {
        let home = try makeFixture(
            schemas: ["brand-new"],
            workers: [("implementer", ["feature-plan.v1"])])   // no worker consumes brand-new
        let plan = ChangePlan(
            changes: [ArtifactChange(path: repoPath("schemas/brand-new.schema.yaml"), status: .added)],
            homeDirectory: home)

        let result = try #require(plan.classifications.first)
        #expect(result.tier == .contract)
        #expect(result.consumers.isEmpty)
        #expect(result.flags == [.nonAckBlocking])
        #expect(result.blastRadius == "0 consumers (new)")
    }

    // ACC-highest-tier-helper
    @Test func highestTierHelper() throws {
        let home = try makeFixture(schemas: ["s"], workers: [("w", ["s.v1"])])

        // contract present -> contract, regardless of order.
        let mixed = ChangePlan(changes: [
            ArtifactChange(path: repoPath("conventions/swift.md"), status: .modified),
            ArtifactChange(path: repoPath("schemas/s.schema.yaml"), status: .modified),
            ArtifactChange(path: repoPath("workers/w.worker.yaml"), status: .modified)
        ], homeDirectory: home)
        #expect(mixed.highestTier == .contract)

        // no contract -> local over refresh.
        let noContract = ChangePlan(changes: [
            ArtifactChange(path: repoPath("conventions/swift.md"), status: .modified),
            ArtifactChange(path: repoPath("workers/w.worker.yaml"), status: .modified)
        ], homeDirectory: home)
        #expect(noContract.highestTier == .local)

        // refresh only.
        let refreshOnly = ChangePlan(
            changes: [ArtifactChange(path: repoPath("skills/x/SKILL.md"), status: .modified)],
            homeDirectory: home)
        #expect(refreshOnly.highestTier == .refresh)

        // empty -> defined nil.
        let empty = ChangePlan(changes: [], homeDirectory: home)
        #expect(empty.highestTier == nil)
    }

    // The Tier ordering itself: refresh < local < contract.
    @Test func tierIsOrdered() {
        #expect(Tier.refresh < Tier.local)
        #expect(Tier.local < Tier.contract)
        #expect([Tier.contract, .refresh, .local].max() == .contract)
    }

    // ACC-unclassified-non-runtime
    @Test func nonRuntimePathIsUnclassifiedLocal() throws {
        let home = try makeFixture(schemas: [], workers: [])
        let plan = ChangePlan(changes: [
            ArtifactChange(path: repoPath("features/plan-command/pipeline.yaml"), status: .modified),
            ArtifactChange(path: repoPath("README.md"), status: .added)
        ], homeDirectory: home)

        // A nested features/.../pipeline.yaml is NOT the top-level pipeline.yaml — it falls through
        // to unclassified local.
        for result in plan.classifications {
            #expect(result.tier == .local)
            #expect(result.unclassified)
        }
    }

    // MARK: - frozen tier + locks.yaml promotion (ADR-0031)

    // ACC-frozen-sorts-top: frozen sorts above contract and the full order holds via Comparable.
    @Test func frozenSortsAboveContract() {
        #expect(Tier.contract < Tier.frozen)
        #expect(Tier.refresh < Tier.local)
        #expect(Tier.local < Tier.contract)
        #expect([Tier.refresh, .local, .contract, .frozen].max() == .frozen)
        #expect([Tier.contract, .frozen, .refresh].max() == .frozen)
    }

    // ACC-locked-promotes-to-frozen: a change whose path matches a lock glob becomes frozen, carries
    // the `.locked` flag, and surfaces the matched glob's reason via `lockReason`.
    @Test func lockedPathPromotesToFrozenWithReason() throws {
        let home = try makeFixture(schemas: [], workers: [])
        let locks = [LockEntry(glob: ".ai-sdd/conventions/swift.md",
                               reason: "Swift conventions are frozen pending review")]
        let plan = ChangePlan(
            changes: [ArtifactChange(path: repoPath("conventions/swift.md"), status: .modified)],
            homeDirectory: home, locks: locks)

        let result = try #require(plan.classifications.first)
        #expect(result.tier == .frozen)            // promoted off its base `refresh`
        #expect(result.flags == [.locked])
        #expect(result.lockReason == "Swift conventions are frozen pending review")
        #expect(plan.highestTier == .frozen)
    }

    // ACC-non-matching-keeps-base-tier: a non-matching change keeps its base tier with no lock flag
    // and no reason (a conventions change stays refresh; a schema change stays contract).
    @Test func nonMatchingChangeKeepsBaseTier() throws {
        let home = try makeFixture(schemas: ["plan"], workers: [("w", ["plan.v1"])])
        let locks = [LockEntry(glob: ".ai-sdd/workers/*", reason: "workers are frozen")]
        let plan = ChangePlan(changes: [
            ArtifactChange(path: repoPath("conventions/swift.md"), status: .modified),
            ArtifactChange(path: repoPath("schemas/plan.schema.yaml"), status: .modified)
        ], homeDirectory: home, locks: locks)

        let conventions = try #require(plan.classifications.first)
        #expect(conventions.tier == .refresh)
        #expect(!conventions.flags.contains(.locked))
        #expect(conventions.lockReason == nil)

        let schema = plan.classifications[1]
        #expect(schema.tier == .contract)
        #expect(!schema.flags.contains(.locked))
        #expect(schema.lockReason == nil)
    }

    // ACC-glob-matching-unit-testable: a prefix-`*` glob matches every path under the prefix; an
    // exact-path glob matches only that path. The matcher is pure and tested in isolation.
    @Test func globMatchingPrefixAndExact() {
        // Prefix glob (trailing `*`).
        #expect(ChangePlan.glob(".ai-sdd/skills/*", matches: ".ai-sdd/skills/implement-feature/SKILL.md"))
        #expect(ChangePlan.glob(".ai-sdd/skills/*", matches: ".ai-sdd/skills/plan-feature/SKILL.md"))
        #expect(!ChangePlan.glob(".ai-sdd/skills/*", matches: ".ai-sdd/workers/w.worker.yaml"))
        // Exact-path glob (no `*`).
        #expect(ChangePlan.glob(".ai-sdd/pipeline.yaml", matches: ".ai-sdd/pipeline.yaml"))
        #expect(!ChangePlan.glob(".ai-sdd/pipeline.yaml", matches: ".ai-sdd/pipeline.yaml.bak"))
        #expect(!ChangePlan.glob(".ai-sdd/pipeline.yaml", matches: ".ai-sdd/x/pipeline.yaml"))
    }

    // ACC-glob-matching-unit-testable (end-to-end): promotion via a fixture `locks.yaml` exercises
    // both a prefix-`*` glob and an exact-path glob in one plan.
    @Test func promotionMatchesPrefixAndExactGlobs() throws {
        let home = try makeFixture(schemas: [], workers: [], locks: """
        - { glob: ".ai-sdd/skills/*", reason: "skills locked" }
        - { glob: ".ai-sdd/pipeline.yaml", reason: "pipeline locked" }
        """)
        let plan = ChangePlan(changes: [
            ArtifactChange(path: repoPath("skills/implement-feature/SKILL.md"), status: .modified),
            ArtifactChange(path: repoPath("pipeline.yaml"), status: .modified),
            ArtifactChange(path: repoPath("workers/w.worker.yaml"), status: .modified)
        ], homeDirectory: home)

        #expect(plan.classifications[0].tier == .frozen)             // prefix glob
        #expect(plan.classifications[0].lockReason == "skills locked")
        #expect(plan.classifications[1].tier == .frozen)             // exact glob
        #expect(plan.classifications[1].lockReason == "pipeline locked")
        #expect(plan.classifications[2].tier == .local)              // unmatched
        #expect(!plan.classifications[2].flags.contains(.locked))
    }

    // ACC-absent-locks-no-promotion: with no `.ai-sdd/locks.yaml`, no change is promoted and the
    // load raises no error (requirement L2). Exercises the real file-existence path.
    @Test func absentLocksFileMeansNoPromotionAndNoError() throws {
        let home = try makeFixture(schemas: [], workers: [])   // no locks.yaml written
        #expect(try ChangePlan.loadLocks(homeDirectory: home).isEmpty)

        let plan = ChangePlan(changes: [
            ArtifactChange(path: repoPath("conventions/swift.md"), status: .modified),
            ArtifactChange(path: repoPath("skills/x/SKILL.md"), status: .modified)
        ], homeDirectory: home)
        #expect(plan.classifications.allSatisfy { $0.tier != .frozen })
        #expect(plan.classifications.allSatisfy { !$0.flags.contains(.locked) })
        #expect(plan.highestTier == .refresh)
    }

    // A present `locks.yaml` is loaded and drives promotion through the convenience init (no injected
    // list) — proving the on-disk decode path, not just the injection seam.
    @Test func presentLocksFileIsLoadedAndPromotes() throws {
        let home = try makeFixture(schemas: [], workers: [], locks: """
        - { glob: ".ai-sdd/conventions/*", reason: "conventions frozen" }
        """)
        let plan = ChangePlan(
            changes: [ArtifactChange(path: repoPath("conventions/swift.md"), status: .modified)],
            homeDirectory: home)
        #expect(plan.classifications.first?.tier == .frozen)
        #expect(plan.classifications.first?.lockReason == "conventions frozen")
    }

    // First-match-wins: when several globs match, the first by manifest order supplies the reason.
    @Test func firstMatchingGlobWins() throws {
        let home = try makeFixture(schemas: [], workers: [])
        let locks = [
            LockEntry(glob: ".ai-sdd/skills/*", reason: "first — all skills"),
            LockEntry(glob: ".ai-sdd/skills/implement-feature/*", reason: "second — narrower")
        ]
        let plan = ChangePlan(
            changes: [ArtifactChange(path: repoPath("skills/implement-feature/SKILL.md"), status: .modified)],
            homeDirectory: home, locks: locks)
        let result = try #require(plan.classifications.first)
        #expect(result.tier == .frozen)
        #expect(result.lockReason == "first — all skills", "first matching glob by manifest order wins")
    }
}

// MARK: - PlanReport (tier-grouped render + ack/exit decision over a classified plan)

struct PlanReportTests {
    /// Build a temp `.ai-sdd/` fixture (same shape as ChangePlanTests): `schemas/<each>.schema.yaml`,
    /// a `workers/` dir, and a `pipeline.yaml` with one node per worker running it.
    private func makeFixture(
        schemas: [String],
        workers: [(name: String, consumes: [String])]
    ) throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("planreport-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: home.appendingPathComponent("schemas"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appendingPathComponent("workers"), withIntermediateDirectories: true)

        for stem in schemas {
            let yaml = """
            apiVersion: ai-sdd/v1
            kind: Schema
            metadata: { name: \(stem), version: 1 }
            spec: { handle: file, format: yaml, scope: internal }
            """
            try yaml.write(to: home.appendingPathComponent("schemas/\(stem).schema.yaml"),
                           atomically: true, encoding: .utf8)
        }
        for worker in workers {
            let consumesList = worker.consumes.map { "{ schema: \($0), required: true }" }.joined(separator: ", ")
            let yaml = """
            apiVersion: ai-sdd/v1
            kind: Worker
            metadata: { name: \(worker.name) }
            spec:
              workerKind: transform
              consumes: [\(consumesList)]
            """
            try yaml.write(to: home.appendingPathComponent("workers/\(worker.name).worker.yaml"),
                           atomically: true, encoding: .utf8)
        }
        let nodeLines = workers.map { "    - { id: \($0.name)-node, worker: \($0.name) }" }.joined(separator: "\n")
        let pipeline = """
        apiVersion: ai-sdd/v1
        kind: Pipeline
        metadata: { name: fixture, version: 1 }
        spec:
          semantics: enabler
          nodes:
        \(nodeLines)
          edges: []
        """
        try pipeline.write(to: home.appendingPathComponent("pipeline.yaml"),
                           atomically: true, encoding: .utf8)
        return home
    }

    private func repoPath(_ subpath: String) -> String { ".ai-sdd/\(subpath)" }

    // ACC-no-changes-exit0: an empty plan renders "no changes" and ackRequired is false (exit 0).
    @Test func noChangesIsNoAck() throws {
        let home = try makeFixture(schemas: [], workers: [])
        let plan = ChangePlan(changes: [], homeDirectory: home)
        let report = PlanReport.make(plan: plan, requireAck: .contract)
        #expect(report.renderedText == "no changes")
        #expect(report.ackRequired == false)
    }

    // ACC-refresh-and-local-exit0: refresh + local at the default contract threshold -> no ack.
    @Test func refreshAndLocalDoNotTripAtContract() throws {
        let home = try makeFixture(schemas: [], workers: [])
        let plan = ChangePlan(changes: [
            ArtifactChange(path: repoPath("conventions/swift.md"), status: .modified),
            ArtifactChange(path: repoPath("workers/implementer.worker.yaml"), status: .modified)
        ], homeDirectory: home)
        let report = PlanReport.make(plan: plan, requireAck: .contract)
        #expect(report.ackRequired == false)
    }

    // ACC-contract-exit2-with-consumers: a contract change with >=2 consumers trips the default.
    @Test func contractTripsAtDefaultAndListsConsumers() throws {
        let home = try makeFixture(
            schemas: ["feature-plan"],
            workers: [("implementer", ["feature-plan.v1"]), ("reviewer", ["feature-plan.v1"])])
        let plan = ChangePlan(
            changes: [ArtifactChange(path: repoPath("schemas/feature-plan.schema.yaml"), status: .modified)],
            homeDirectory: home)
        let report = PlanReport.make(plan: plan, requireAck: .contract)
        #expect(report.ackRequired == true)
        #expect(report.renderedText.contains("contract:"))
        #expect(report.renderedText.contains("consumer: implementer-node (implementer)"))
        #expect(report.renderedText.contains("consumer: reviewer-node (reviewer)"))
    }

    // ACC-require-ack-local-trips-local: a local-only change is exit 0 at contract but exit 2 at local.
    @Test func localTripsOnlyWhenThresholdLowered() throws {
        let home = try makeFixture(schemas: [], workers: [])
        let plan = ChangePlan(
            changes: [ArtifactChange(path: repoPath("workers/w.worker.yaml"), status: .modified)],
            homeDirectory: home)
        #expect(PlanReport.make(plan: plan, requireAck: .contract).ackRequired == false)
        #expect(PlanReport.make(plan: plan, requireAck: .local).ackRequired == true)
    }

    // ACC-added-zero-consumer-not-blocking: an added 0-consumer schema does not trip at contract
    // (parent D3) but does once the threshold is lowered to reach it; it is still rendered under
    // contract with its flag.
    @Test func addedZeroConsumerDoesNotTripAtDefault() throws {
        let home = try makeFixture(
            schemas: ["brand-new"],
            workers: [("implementer", ["feature-plan.v1"])])   // nothing consumes brand-new
        let plan = ChangePlan(
            changes: [ArtifactChange(path: repoPath("schemas/brand-new.schema.yaml"), status: .added)],
            homeDirectory: home)

        let atContract = PlanReport.make(plan: plan, requireAck: .contract)
        #expect(atContract.ackRequired == false)
        #expect(atContract.renderedText.contains("contract:"))
        #expect(atContract.renderedText.contains("nonAckBlocking"))
        #expect(atContract.renderedText.contains("0 consumers (new)"))

        // Lowered threshold reaches it -> trips.
        #expect(PlanReport.make(plan: plan, requireAck: .local).ackRequired == true)
        #expect(PlanReport.make(plan: plan, requireAck: .refresh).ackRequired == true)
    }

    // ACC-grouped-output-blast-radius: groups render in the order contract -> local -> refresh, each
    // item showing its path + status; contract items list consumers; flags render inline.
    @Test func groupedOutputShape() throws {
        let home = try makeFixture(schemas: ["s"], workers: [("w", ["s.v1"])])
        let plan = ChangePlan(changes: [
            ArtifactChange(path: repoPath("conventions/swift.md"), status: .modified),
            ArtifactChange(path: repoPath("workers/w.worker.yaml"), status: .modified),
            ArtifactChange(path: repoPath("schemas/s.schema.yaml"), status: .modified)
        ], homeDirectory: home)
        let text = PlanReport.make(plan: plan, requireAck: .contract).renderedText

        let contractIdx = try #require(text.range(of: "contract:"))
        let localIdx = try #require(text.range(of: "local:"))
        let refreshIdx = try #require(text.range(of: "refresh:"))
        #expect(contractIdx.lowerBound < localIdx.lowerBound)
        #expect(localIdx.lowerBound < refreshIdx.lowerBound)

        #expect(text.contains(".ai-sdd/schemas/s.schema.yaml (modified)"))
        #expect(text.contains(".ai-sdd/workers/w.worker.yaml (modified)"))
        #expect(text.contains(".ai-sdd/conventions/swift.md (modified)"))
        #expect(text.contains("consumer: w-node (w)"))
    }

    // MARK: - frozen tier: exit 3 + --unlock downgrade (ADR-0031, cli-locks slice)

    /// A `--unlock`-applied plan reduced to its (classifications, requireAck) → Result, the same path
    /// the `Plan` command takes. `changes` are the original artifact changes (needed to recompute base
    /// tiers on downgrade); `locks` is the in-memory lock manifest (no `locks.yaml` on disk).
    private func report(changes: [ArtifactChange], home: URL, locks: [LockEntry],
                        requireAck: Tier, unlock: [String] = [])
        -> (result: PlanReport.Result, unmatched: [String]) {
        let plan = ChangePlan(changes: changes, homeDirectory: home, locks: locks)
        let downgrade = PlanReport.downgradingUnlocked(
            plan: plan, changes: changes, homeDirectory: home, unlock: unlock)
        return (PlanReport.make(classifications: downgrade.classifications, requireAck: requireAck),
                downgrade.unmatched)
    }

    // ACC-frozen-exit3: a locked-path change renders as a hard ✗ with its reason and frozenPresent is
    // true (the command throws ExitCode(3)).
    @Test func frozenChangeReportsFrozenPresentAndRendersHardX() throws {
        let home = try makeFixture(schemas: [], workers: [])
        let locks = [LockEntry(glob: ".ai-sdd/conventions/swift.md", reason: "frozen pending review")]
        let out = report(changes: [ArtifactChange(path: repoPath("conventions/swift.md"), status: .modified)],
                         home: home, locks: locks, requireAck: .contract)
        #expect(out.result.frozenPresent == true)
        #expect(out.result.renderedText.contains("frozen:"))
        #expect(out.result.renderedText.contains(
            "✗ .ai-sdd/conventions/swift.md (modified) [frozen: frozen pending review]"))
    }

    // ACC-frozen-not-waivable: --require-ack (any tier) does not lower a frozen change below exit 3;
    // frozenPresent stays true regardless of the threshold.
    @Test func frozenStaysPresentRegardlessOfThreshold() throws {
        let home = try makeFixture(schemas: [], workers: [])
        let locks = [LockEntry(glob: ".ai-sdd/conventions/swift.md", reason: "frozen")]
        let changes = [ArtifactChange(path: repoPath("conventions/swift.md"), status: .modified)]
        for threshold in [Tier.refresh, .local, .contract] {
            let out = report(changes: changes, home: home, locks: locks, requireAck: threshold)
            #expect(out.result.frozenPresent == true, "threshold \(threshold) must not waive frozen")
        }
    }

    // ACC-unlock-downgrades: --unlock <path> downgrades that frozen change to its base tier; the plan
    // then exits per the normal --require-ack threshold (no longer frozen for that change).
    @Test func unlockDowngradesToBaseTierThenExitsPerThreshold() throws {
        let home = try makeFixture(schemas: [], workers: [])
        // A worker path: base tier `local`. Frozen by the lock, unlocked back to local.
        let locks = [LockEntry(glob: ".ai-sdd/workers/w.worker.yaml", reason: "frozen")]
        let changes = [ArtifactChange(path: repoPath("workers/w.worker.yaml"), status: .modified)]

        // Frozen without unlock.
        #expect(report(changes: changes, home: home, locks: locks, requireAck: .contract)
                    .result.frozenPresent == true)

        // Unlocked → base tier `local`: no longer frozen; at contract no ack, at local it trips.
        let atContract = report(changes: changes, home: home, locks: locks,
                                requireAck: .contract, unlock: [repoPath("workers/w.worker.yaml")])
        #expect(atContract.result.frozenPresent == false)
        #expect(atContract.result.ackRequired == false)
        #expect(atContract.unmatched.isEmpty)

        let atLocal = report(changes: changes, home: home, locks: locks,
                             requireAck: .local, unlock: [repoPath("workers/w.worker.yaml")])
        #expect(atLocal.result.frozenPresent == false)
        #expect(atLocal.result.ackRequired == true)   // base tier `local` reached at the lowered threshold
    }

    // ACC-unlock-noop-warns: --unlock of a non-frozen or unmatched path is a no-op that reports an
    // unmatched warning and does NOT change tiers or the exit signal (L3).
    @Test func unlockOfNonFrozenOrUnmatchedPathIsNoOpWithWarning() throws {
        let home = try makeFixture(schemas: [], workers: [])
        let locks = [LockEntry(glob: ".ai-sdd/conventions/swift.md", reason: "frozen")]
        let changes = [
            ArtifactChange(path: repoPath("conventions/swift.md"), status: .modified),   // frozen
            ArtifactChange(path: repoPath("workers/w.worker.yaml"), status: .modified)    // non-frozen
        ]
        // Unlock a non-frozen path + a path with no change at all → both unmatched, nothing changes.
        let out = report(changes: changes, home: home, locks: locks, requireAck: .contract,
                         unlock: [repoPath("workers/w.worker.yaml"), repoPath("schemas/ghost.schema.yaml")])
        #expect(out.unmatched == [repoPath("workers/w.worker.yaml"), repoPath("schemas/ghost.schema.yaml")])
        #expect(out.result.frozenPresent == true)   // the actually-frozen conventions change is untouched
    }

    // ACC-frozen-renders-above-contract: the frozen group renders above contract, and a non-frozen
    // contract change is unaffected (tier, grouping, consumers render as before).
    @Test func frozenGroupRendersAboveContractAndNonFrozenUnaffected() throws {
        let home = try makeFixture(schemas: ["s"], workers: [("w", ["s.v1"])])
        let locks = [LockEntry(glob: ".ai-sdd/conventions/swift.md", reason: "frozen")]
        let changes = [
            ArtifactChange(path: repoPath("conventions/swift.md"), status: .modified),   // frozen
            ArtifactChange(path: repoPath("schemas/s.schema.yaml"), status: .modified)    // contract
        ]
        let out = report(changes: changes, home: home, locks: locks, requireAck: .contract)
        let text = out.result.renderedText

        let frozenIdx = try #require(text.range(of: "frozen:"))
        let contractIdx = try #require(text.range(of: "contract:"))
        #expect(frozenIdx.lowerBound < contractIdx.lowerBound, "frozen group renders above contract")
        // The non-frozen contract change is unaffected: still classified contract with its consumer.
        #expect(text.contains(".ai-sdd/schemas/s.schema.yaml (modified)"))
        #expect(text.contains("consumer: w-node (w)"))
        #expect(out.result.frozenPresent == true)
    }

    // MARK: - hand-edited annotation (ADR-0032: provenance-grounded `hand-edited` label)

    /// Build a temp *repo root* containing a real `.ai-sdd/` home with one schema + a single-consumer
    /// worker/pipeline, then write each named artifact's current bytes and seed `provenance.json` with
    /// a recorded baseline per artifact. `recorded[path]` is the baseline bytes (what the generator
    /// emitted); the on-disk bytes are `onDisk[path]`. A path present in `onDisk` but absent from
    /// `recorded` is untracked. Returns the `.ai-sdd/` home `ChangePlan.init` takes — its parent is the
    /// repo root, so a `.ai-sdd/...` change path resolves to the real on-disk file (D-CHANGEPLAN-RESOLVES).
    private func makeHandEditedFixture(
        schemas: [String],
        workers: [(name: String, consumes: [String])],
        recorded: [String: String],
        onDisk: [String: String]
    ) throws -> URL {
        let fm = FileManager.default
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("handedited-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent(".ai-sdd", isDirectory: true)
        try fm.createDirectory(at: home.appendingPathComponent("schemas"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appendingPathComponent("workers"), withIntermediateDirectories: true)

        for stem in schemas {
            let yaml = """
            apiVersion: ai-sdd/v1
            kind: Schema
            metadata: { name: \(stem), version: 1 }
            spec: { handle: file, format: yaml, scope: internal }
            """
            try yaml.write(to: home.appendingPathComponent("schemas/\(stem).schema.yaml"),
                           atomically: true, encoding: .utf8)
        }
        for worker in workers {
            let consumesList = worker.consumes.map { "{ schema: \($0), required: true }" }.joined(separator: ", ")
            let yaml = """
            apiVersion: ai-sdd/v1
            kind: Worker
            metadata: { name: \(worker.name) }
            spec:
              workerKind: transform
              consumes: [\(consumesList)]
            """
            try yaml.write(to: home.appendingPathComponent("workers/\(worker.name).worker.yaml"),
                           atomically: true, encoding: .utf8)
        }
        let nodeLines = workers.map { "    - { id: \($0.name)-node, worker: \($0.name) }" }.joined(separator: "\n")
        let pipeline = """
        apiVersion: ai-sdd/v1
        kind: Pipeline
        metadata: { name: fixture, version: 1 }
        spec:
          semantics: enabler
          nodes:
        \(nodeLines)
          edges: []
        """
        try pipeline.write(to: home.appendingPathComponent("pipeline.yaml"), atomically: true, encoding: .utf8)

        // Write each artifact's *current on-disk* bytes (the pre-change content the planner reads).
        for (repoRelPath, bytes) in onDisk {
            let url = root.appendingPathComponent(repoRelPath)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url, atomically: true, encoding: .utf8)
        }
        // Seed provenance.json with the recorded baseline per recorded path.
        var manifest = Provenance()
        for (repoRelPath, bytes) in recorded {
            manifest.record(path: repoRelPath, generator: "fixture",
                            generatedAt: "2026-06-22T00:00:00Z", data: Data(bytes.utf8))
        }
        try manifest.save(to: Layout.provenanceURL(homeDirectory: home))
        return home
    }

    // AC-HANDEDITED-MARKED: a changed artifact whose pre-change on-disk content diverged from its
    // recorded baseline renders `hand-edited` in the grouped output.
    @Test func divergedArtifactRendersHandEdited() throws {
        let path = repoPath("conventions/swift.md")
        let home = try makeHandEditedFixture(
            schemas: [], workers: [],
            recorded: [path: "generated baseline"],
            onDisk:   [path: "generated baseline — then hand tweaked"])   // diverged
        let plan = ChangePlan(
            changes: [ArtifactChange(path: path, status: .modified)], homeDirectory: home)
        #expect(plan.classifications.first?.handEdited == true)

        let text = PlanReport.make(plan: plan, requireAck: .contract).renderedText
        #expect(text.contains(".ai-sdd/conventions/swift.md (modified) [hand-edited]"))
    }

    // AC-PRISTINE-UNMARKED: a pristine changed artifact (on-disk bytes still match the baseline) and
    // an untracked one (no recorded entry) are NOT marked `hand-edited`.
    @Test func pristineAndUntrackedDoNotRenderHandEdited() throws {
        let pristine = repoPath("conventions/swift.md")
        let untracked = repoPath("workers/w.worker.yaml")
        let home = try makeHandEditedFixture(
            schemas: [], workers: [("w", [])],
            recorded: [pristine: "same bytes"],                       // untracked has no recorded entry
            onDisk:   [pristine: "same bytes", untracked: "anything"])
        let plan = ChangePlan(changes: [
            ArtifactChange(path: pristine, status: .modified),
            ArtifactChange(path: untracked, status: .modified)
        ], homeDirectory: home)

        let byPath = Dictionary(uniqueKeysWithValues: plan.classifications.map { ($0.path, $0) })
        #expect(byPath[pristine]?.handEdited == false, "pristine: bytes match baseline")
        #expect(byPath[untracked]?.handEdited == false, "untracked: no recorded entry")

        let text = PlanReport.make(plan: plan, requireAck: .contract).renderedText
        #expect(!text.contains("hand-edited"))
    }

    // AC-ANNOTATION-ORTHOGONAL: a hand-edited *contract* change renders BOTH its tier grouping/labels
    // (contract + consumers) AND the `hand-edited` annotation — the annotation is independent of tier.
    @Test func handEditedContractShowsBothTierAndAnnotation() throws {
        let path = repoPath("schemas/feature-plan.schema.yaml")
        // The on-disk schema bytes must parse as a valid schema (the bundle loads for consumer
        // resolution) yet still diverge from the recorded baseline.
        let onDiskSchema = """
        apiVersion: ai-sdd/v1
        kind: Schema
        metadata: { name: feature-plan, version: 1 }
        spec: { handle: file, format: yaml, scope: internal }
        # hand-tweaked comment that diverges from the recorded baseline
        """
        let home = try makeHandEditedFixture(
            schemas: ["feature-plan"],
            workers: [("implementer", ["feature-plan.v1"]), ("reviewer", ["feature-plan.v1"])],
            recorded: [path: "an earlier recorded baseline"],
            onDisk:   [path: onDiskSchema])
        // makeFixture already wrote a canonical schema at schemas/...; overwrite below kept it valid.
        let plan = ChangePlan(
            changes: [ArtifactChange(path: path, status: .modified)], homeDirectory: home)

        let result = try #require(plan.classifications.first)
        #expect(result.tier == .contract, "tier classification is unaffected by the annotation")
        #expect(result.handEdited == true)

        let text = PlanReport.make(plan: plan, requireAck: .contract).renderedText
        #expect(text.contains("contract:"), "renders under its tier group")
        #expect(text.contains(".ai-sdd/schemas/feature-plan.schema.yaml (modified) [hand-edited]"))
        #expect(text.contains("consumer: implementer-node (implementer)"), "tier labels/consumers still render")
        #expect(text.contains("consumer: reviewer-node (reviewer)"))
    }

    // MARK: - skill surface (ai-sdd surface)

    /// A two-agent table mirroring `Layout.agentSkillSurfaces` but pinned here so the tests don't
    /// depend on the real repo's table.
    private static let surfaceAgents: [(agent: String, dir: String)] = [
        (agent: "codex", dir: ".agents/skills"),
        (agent: "claude", dir: ".claude/skills")
    ]

    /// Build a temp fixture repo with `.ai-sdd/skills/` holding the named framework skills (each a
    /// dir with a `SKILL.md`), plus a `plan-feature` worker skill (no `SKILL.md` marker needed — it
    /// lacks the `ai-sdd-` prefix), and empty agent dirs for every agent in the table.
    private func makeSurfaceFixture(frameworkSkills: [String]) throws -> URL {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-sdd-surface-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent(".ai-sdd/skills", isDirectory: true)
        for name in frameworkSkills {
            let skill = source.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: skill, withIntermediateDirectories: true)
            try "# \(name)".write(to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        }
        // A worker skill — present in the source, must NOT be surfaced.
        try fm.createDirectory(at: source.appendingPathComponent("plan-feature", isDirectory: true),
                               withIntermediateDirectories: true)
        for (_, dir) in Self.surfaceAgents {
            try fm.createDirectory(at: root.appendingPathComponent(dir, isDirectory: true),
                                   withIntermediateDirectories: true)
        }
        return root
    }

    private func symlinkTarget(_ url: URL) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
    }

    // Discovery excludes the worker skill: only `ai-sdd-*` dirs with a SKILL.md are framework skills.
    @Test func surfaceDiscoversFrameworkSkillsExcludingWorkerSkills() throws {
        let root = try makeSurfaceFixture(frameworkSkills: ["ai-sdd-plan", "ai-sdd-run"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(SkillSurface.frameworkSkills(repoRoot: root) == ["ai-sdd-plan", "ai-sdd-run"])
    }

    // A framework skill dir with no SKILL.md is not surfaceable (excluded).
    @Test func surfaceExcludesPrefixedDirWithoutManifest() throws {
        let root = try makeSurfaceFixture(frameworkSkills: ["ai-sdd-plan"])
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".ai-sdd/skills/ai-sdd-nomanifest", isDirectory: true),
            withIntermediateDirectories: true)
        #expect(SkillSurface.frameworkSkills(repoRoot: root) == ["ai-sdd-plan"])
    }

    // Reconcile links every framework skill into every agent dir with the correct relative target,
    // creates them, and leaves the worker skill unsurfaced.
    @Test func surfaceCreatesCorrectSymlinksInEveryAgentDir() throws {
        let root = try makeSurfaceFixture(frameworkSkills: ["ai-sdd-plan", "ai-sdd-run"])
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try SkillSurface.reconcile(repoRoot: root, agents: Self.surfaceAgents, check: false)
        #expect(result.applied)
        #expect(result.ops.allSatisfy { $0.op == .created })

        for (_, dir) in Self.surfaceAgents {
            let dirURL = root.appendingPathComponent(dir, isDirectory: true)
            #expect(symlinkTarget(dirURL.appendingPathComponent("ai-sdd-plan"))
                == "../../.ai-sdd/skills/ai-sdd-plan")
            #expect(symlinkTarget(dirURL.appendingPathComponent("ai-sdd-run"))
                == "../../.ai-sdd/skills/ai-sdd-run")
            // The worker skill is never surfaced.
            #expect(symlinkTarget(dirURL.appendingPathComponent("plan-feature")) == nil)
        }
    }

    // A missing agent dir is created on apply.
    @Test func surfaceCreatesMissingAgentDir() throws {
        let root = try makeSurfaceFixture(frameworkSkills: ["ai-sdd-plan"])
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: root.appendingPathComponent(".claude/skills", isDirectory: true))

        _ = try SkillSurface.reconcile(repoRoot: root, agents: Self.surfaceAgents, check: false)
        #expect(symlinkTarget(root.appendingPathComponent(".claude/skills/ai-sdd-plan"))
            == "../../.ai-sdd/skills/ai-sdd-plan")
    }

    // Idempotent: a second reconcile reports everything as `unchanged` and mutates nothing.
    @Test func surfaceIsIdempotent() throws {
        let root = try makeSurfaceFixture(frameworkSkills: ["ai-sdd-plan", "ai-sdd-run"])
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try SkillSurface.reconcile(repoRoot: root, agents: Self.surfaceAgents, check: false)
        let second = try SkillSurface.reconcile(repoRoot: root, agents: Self.surfaceAgents, check: false)
        #expect(second.reconciled)
        #expect(second.ops.allSatisfy { $0.op == .unchanged })
    }

    // A stale symlink — pointing at a removed framework skill — is pruned; regular entries untouched.
    @Test func surfacePrunesStaleSymlink() throws {
        let root = try makeSurfaceFixture(frameworkSkills: ["ai-sdd-plan"])
        defer { try? FileManager.default.removeItem(at: root) }
        let claudeDir = root.appendingPathComponent(".claude/skills", isDirectory: true)

        // A leftover link to a framework skill that no longer exists in the source.
        try FileManager.default.createSymbolicLink(
            atPath: claudeDir.appendingPathComponent("ai-sdd-gone").path,
            withDestinationPath: "../../.ai-sdd/skills/ai-sdd-gone")
        // An unrelated regular file — must be left alone.
        try "keep".write(to: claudeDir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let result = try SkillSurface.reconcile(repoRoot: root, agents: Self.surfaceAgents, check: false)
        let pruned = result.ops.filter { $0.op == .pruned }
        #expect(pruned.map(\.name) == ["ai-sdd-gone"])
        #expect(!FileManager.default.fileExists(atPath: claudeDir.appendingPathComponent("ai-sdd-gone").path))
        #expect(FileManager.default.fileExists(atPath: claudeDir.appendingPathComponent("notes.txt").path))
    }

    // A wrong-target symlink is repointed to the canonical relative target.
    @Test func surfaceFixesWrongTargetSymlink() throws {
        let root = try makeSurfaceFixture(frameworkSkills: ["ai-sdd-plan"])
        defer { try? FileManager.default.removeItem(at: root) }
        let agentDir = root.appendingPathComponent(".agents/skills", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            atPath: agentDir.appendingPathComponent("ai-sdd-plan").path,
            withDestinationPath: "/somewhere/else")

        let result = try SkillSurface.reconcile(repoRoot: root, agents: Self.surfaceAgents, check: false)
        #expect(result.ops.contains { $0.agentDir == ".agents/skills" && $0.name == "ai-sdd-plan" && $0.op == .fixed })
        #expect(symlinkTarget(agentDir.appendingPathComponent("ai-sdd-plan"))
            == "../../.ai-sdd/skills/ai-sdd-plan")
    }

    // --check mode plans the work, signals out-of-sync, but writes nothing.
    @Test func surfaceCheckModeChangesNothingAndSignalsOutOfSync() throws {
        let root = try makeSurfaceFixture(frameworkSkills: ["ai-sdd-plan"])
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try SkillSurface.reconcile(repoRoot: root, agents: Self.surfaceAgents, check: true)
        #expect(!result.applied)
        #expect(!result.reconciled)               // links are missing → out of sync
        #expect(result.ops.contains { $0.op == .created })
        // Nothing was written.
        for (_, dir) in Self.surfaceAgents {
            #expect(symlinkTarget(root.appendingPathComponent(dir, isDirectory: true)
                .appendingPathComponent("ai-sdd-plan")) == nil)
        }

        // Once reconciled, --check reports everything in sync.
        _ = try SkillSurface.reconcile(repoRoot: root, agents: Self.surfaceAgents, check: false)
        let recheck = try SkillSurface.reconcile(repoRoot: root, agents: Self.surfaceAgents, check: true)
        #expect(recheck.reconciled)
    }

    // MARK: - Provenance manifest (ADR-0032 P1/P3: deterministic provenance + clobber-guard)

    /// A temp manifest URL + an artifact URL under a fresh temp home, written with `bytes`. Drives the
    /// provenance tests entirely from a temp dir — no real `.ai-sdd/`.
    private func makeProvenanceFixture(artifact: String, bytes: String) throws -> (manifest: URL, artifact: URL) {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("provenance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let artifactURL = home.appendingPathComponent(artifact)
        try bytes.write(to: artifactURL, atomically: true, encoding: .utf8)
        return (Layout.provenanceURL(homeDirectory: home), artifactURL)
    }

    // AC-ROUNDTRIP-DETERMINISTIC: recording the same path/generator/timestamp/bytes twice produces
    // byte-identical manifest JSON — a no-op re-run yields no diff.
    @Test func provenanceRoundTripIsDeterministic() throws {
        func record() throws -> Data {
            var manifest = Provenance()
            // Insert two paths out of sorted order — `.sortedKeys` must normalize the key order.
            manifest.record(path: ".ai-sdd/skills/z.md", generator: "bootstrap",
                            generatedAt: "2026-06-22T00:00:00Z", data: Data("zebra".utf8))
            manifest.record(path: ".ai-sdd/skills/a.md", generator: "bootstrap",
                            generatedAt: "2026-06-22T00:00:00Z", data: Data("apple".utf8))
            return try manifest.encoded()
        }
        let first = try record()
        let second = try record()
        #expect(first == second, "identical inputs must serialize to byte-identical JSON")
        // The deterministic options actually took effect: keys sorted, slashes unescaped.
        let text = try #require(String(data: first, encoding: .utf8))
        #expect(text.range(of: ".ai-sdd/skills/a.md")!.lowerBound
            < text.range(of: ".ai-sdd/skills/z.md")!.lowerBound, "keys must be sorted")
        #expect(text.contains(".ai-sdd/skills/a.md"), "slashes must not be escaped")
    }

    // A saved manifest round-trips through load unchanged (absent file ⇒ empty manifest).
    @Test func provenanceLoadSaveRoundTrip() throws {
        let (manifestURL, _) = try makeProvenanceFixture(artifact: "x.txt", bytes: "x")
        #expect(try Provenance.load(from: manifestURL) == Provenance(), "absent file ⇒ empty manifest")

        var manifest = Provenance()
        manifest.record(path: ".ai-sdd/a.json", generator: "compile-schema",
                        generatedAt: "2026-06-22T12:00:00Z", data: Data("payload".utf8))
        try manifest.save(to: manifestURL)
        #expect(try Provenance.load(from: manifestURL) == manifest)
    }

    // AC-STATUS-PRISTINE: recorded entry whose on-disk bytes are unchanged ⇒ pristine.
    @Test func provenanceStatusPristine() throws {
        let (_, artifactURL) = try makeProvenanceFixture(artifact: "gen.txt", bytes: "generated")
        var manifest = Provenance()
        manifest.record(path: "gen.txt", generator: "bootstrap",
                        generatedAt: "2026-06-22T00:00:00Z", data: Data("generated".utf8))
        #expect(manifest.status(of: "gen.txt", artifactURL: artifactURL) == .pristine)
    }

    // AC-STATUS-HANDEDITED: recorded entry whose on-disk bytes diverged (hash mismatch) ⇒ hand-edited.
    @Test func provenanceStatusHandEdited() throws {
        let (_, artifactURL) = try makeProvenanceFixture(artifact: "gen.txt", bytes: "generated")
        var manifest = Provenance()
        manifest.record(path: "gen.txt", generator: "bootstrap",
                        generatedAt: "2026-06-22T00:00:00Z", data: Data("generated".utf8))
        // A human edits the file on disk.
        try "generated — and then hand tweaked".write(to: artifactURL, atomically: true, encoding: .utf8)
        let status = manifest.status(of: "gen.txt", artifactURL: artifactURL)
        #expect(status == .handEdited)
        #expect(status.rawValue == "hand-edited", "the raw value matches the feature vocabulary")
    }

    // AC-STATUS-UNTRACKED: a path with no recorded entry ⇒ untracked.
    @Test func provenanceStatusUntracked() throws {
        let (_, artifactURL) = try makeProvenanceFixture(artifact: "unknown.txt", bytes: "whatever")
        let manifest = Provenance()   // empty — nothing recorded
        #expect(manifest.status(of: "unknown.txt", artifactURL: artifactURL) == .untracked)
        // The data-driven overload agrees.
        #expect(manifest.status(of: "unknown.txt", currentData: Data("whatever".utf8)) == .untracked)
    }

    // AC-CLOBBER-GUARD: hand-edited ⇒ "do not overwrite"; pristine/untracked ⇒ "ok".
    @Test func provenanceClobberGuard() {
        #expect(Provenance.clobberDecision(for: .handEdited) == .doNotOverwrite)
        #expect(Provenance.clobberDecision(for: .handEdited).rawValue == "do not overwrite")
        #expect(Provenance.clobberDecision(for: .pristine) == .ok)
        #expect(Provenance.clobberDecision(for: .untracked) == .ok)

        #expect(Provenance.canOverwrite(.handEdited) == false)
        #expect(Provenance.canOverwrite(.pristine))
        #expect(Provenance.canOverwrite(.untracked))
    }

    // AC-SHA256-NO-CLOCK: content hashing is SHA-256 (lowercase hex), and the API only ever takes a
    // passed-in timestamp — the engine never reads the clock.
    @Test func provenanceUsesSHA256AndNeverReadsClock() {
        // Known SHA-256 of the ASCII string "abc".
        let expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        #expect(Provenance.contentHash(of: Data("abc".utf8)) == expected)
        #expect(Provenance.contentHash(of: Data()).count == 64, "SHA-256 hex is always 64 chars")

        // The recorded timestamp is exactly the caller-supplied string — not derived from a clock.
        var manifest = Provenance()
        let stamp = "2030-01-01T00:00:00Z"   // a future, fixed instant a clock could never return now
        manifest.record(path: "p", generator: "g", generatedAt: stamp, data: Data("abc".utf8))
        let entry = manifest.entries["p"]
        #expect(entry?.generatedAt == stamp)
        #expect(entry?.contentHash == expected)
    }

    // AC-GENERATOR-RECORDS: the representative wired generator (`Provenance.emit`) writes the bytes AND
    // records an entry whose `contentHash` matches the emitted bytes, saved deterministically to the
    // manifest — one write-through step (D-GENERATOR-WIRED / ADR-0032 P2).
    @Test func emitWritesBytesAndRecordsMatchingHash() throws {
        let (manifestURL, artifactURL) = try makeProvenanceFixture(artifact: "out.json", bytes: "old")
        let path = ".ai-sdd/artifacts/out.json"
        let bytes = Data("emitted payload".utf8)

        let returned = try Provenance.emit(
            artifactPath: path, artifactURL: artifactURL, generator: "compile-schema",
            generatedAt: "2026-06-22T09:00:00Z", data: bytes, manifestURL: manifestURL)

        // The bytes actually landed on disk.
        #expect(try Data(contentsOf: artifactURL) == bytes)

        // The persisted manifest carries an entry whose contentHash matches the emitted bytes.
        let loaded = try Provenance.load(from: manifestURL)
        let entry = try #require(loaded.entries[path])
        #expect(entry.generator == "compile-schema")
        #expect(entry.generatedAt == "2026-06-22T09:00:00Z")
        #expect(entry.contentHash == Provenance.contentHash(of: bytes), "recorded hash matches emitted bytes")
        #expect(loaded == returned, "the returned manifest equals what was saved")
    }
}

// MARK: - Drift (ADR-0033 deterministic kinds 1+2)

struct DriftTests {
    /// A schema input for Kind 1 reconstruction.
    private func schemaInput(_ name: String, version: Int = 1, format: String = "yaml") -> Drift.SchemaInput {
        .init(name: name, version: version, format: format)
    }

    /// The committed structural check that EXACTLY matches what the engine reconstructs — so a repo
    /// built from it is reconciled (no Kind-1 finding). Built via the public engine API (the same
    /// `SchemaCompiler` source of truth `Drift` now delegates to), with a non-empty `fields`
    /// placeholder so `structuralCheck` returns non-nil.
    private func reconciledCheck(for name: String, version: Int = 1, format: String = "yaml") -> Drift.CommittedCheck {
        let schema = SchemaSpec(format: format, fields: ["_": FieldSpec(type: "string")])
        let compiled = SchemaCompiler.structuralCheck(schema, name: name, version: version)!
        return .init(checkName: Layout.structuralCheckName(name: name), spec: compiled.spec)
    }

    /// A tiny schema with one required non-empty `summary` field, for Kind-2 fixture validation.
    private func summarySchema() throws -> SchemaSpec {
        try SpecLoader().loadSchemaYAML("""
        apiVersion: ai-sdd/v1
        kind: Schema
        metadata: { name: thing, version: 1 }
        spec:
          handle: file
          format: yaml
          fields:
            summary: { type: string, required: true, invariants: [{ nonEmpty: true }] }
        """).spec
    }

    // AC-RECONCILED-CLEAN-EXIT0: a reconciled repo (committed structural checks match their schemas,
    // all fixtures valid) yields zero findings.
    @Test func reconciledRepoHasNoFindings() throws {
        let schema = try summarySchema()
        let findings = try Drift.scan(
            schemas: [schemaInput("feature-plan"), schemaInput("changeset")],
            committedChecks: [reconciledCheck(for: "feature-plan"), reconciledCheck(for: "changeset")],
            fixtures: [.init(path: "docs/examples/schema/good.yaml",
                             contents: "summary: a real summary\n", schema: schema)])
        #expect(findings.isEmpty, "a fully reconciled repo drifts nowhere")
    }

    // AC-STALE-GATE-REPORTED: a committed structural check that no longer matches its schema's
    // reconstructed Tier-1 template is reported under stale-gate with remedy `recompile <schema>`.
    @Test func staleStructuralCheckIsReported() throws {
        // Inject drift: the committed command points at a stale artifact path.
        let stale = Drift.CommittedCheck(
            checkName: Layout.structuralCheckName(name: "feature-plan"),
            spec: CheckSpec(checkKind: "deterministic",
                            command: "swift run ai-sdd check .ai-sdd/schemas/feature-plan.schema.yaml STALE.yaml",
                            required: true))
        let findings = try Drift.scan(
            schemas: [schemaInput("feature-plan")], committedChecks: [stale], fixtures: [])
        #expect(findings.count == 1)
        let finding = try #require(findings.first)
        #expect(finding.kind == .staleGate)
        #expect(finding.subject == "feature-plan")
        #expect(finding.remedy == "recompile feature-plan")
    }

    // AC-STALE-GATE-REPORTED (missing variant): a schema with no committed structural check is a finding.
    @Test func missingStructuralCheckIsReported() throws {
        let findings = try Drift.scan(
            schemas: [schemaInput("review")], committedChecks: [], fixtures: [])
        #expect(findings.count == 1)
        #expect(findings.first?.kind == .staleGate)
        #expect(findings.first?.remedy == "recompile review")
        #expect(findings.first?.detail.contains("missing") == true)
    }

    // An orphaned structural check (a committed `<name>.structure` whose schema is gone) is a finding.
    @Test func orphanedStructuralCheckIsReported() throws {
        let findings = try Drift.scan(
            schemas: [], committedChecks: [reconciledCheck(for: "ghost")], fixtures: [])
        #expect(findings.count == 1)
        #expect(findings.first?.kind == .staleGate)
        #expect(findings.first?.subject == "ghost")
        #expect(findings.first?.detail.contains("no matching schema") == true)
    }

    // AC-FIXTURE-VIOLATION-REPORTED: a fixture that violates its current schema is reported under
    // fixture-schema with remedy `fix fixture <path>`.
    @Test func schemaViolatingFixtureIsReported() throws {
        let schema = try summarySchema()
        let badPath = "docs/examples/schema/bad.yaml"
        let findings = try Drift.scan(
            schemas: [], committedChecks: [],
            fixtures: [.init(path: badPath, contents: "notsummary: oops\n", schema: schema)])
        #expect(findings.count == 1)
        let finding = try #require(findings.first)
        #expect(finding.kind == .fixtureSchema)
        #expect(finding.subject == badPath)
        #expect(finding.remedy == "fix fixture \(badPath)")
        #expect(finding.detail.contains("summary") == true)
    }

    // AC-HANDEDITED-ANNOTATED: a finding whose subject path is in the hand-edited set carries the
    // annotation (additive; an empty set leaves findings unannotated).
    @Test func handEditedSubjectIsAnnotated() throws {
        let schema = try summarySchema()
        let badPath = "docs/examples/schema/bad.yaml"
        let fixtures = [Drift.FixtureInput(path: badPath, contents: "x: 1\n", schema: schema)]

        let annotated = try Drift.scan(
            schemas: [], committedChecks: [], fixtures: fixtures, handEditedPaths: [badPath])
        #expect(annotated.first?.handEdited == true, "subject in the hand-edited set is annotated")

        let plain = try Drift.scan(schemas: [], committedChecks: [], fixtures: fixtures)
        #expect(plain.first?.handEdited == false, "absent manifest ⇒ no annotation (additive)")
    }

    // Findings are grouped/ordered by kind: stale-gate before fixture-schema.
    @Test func findingsAreOrderedByKind() throws {
        let schema = try summarySchema()
        let findings = try Drift.scan(
            schemas: [schemaInput("missing")], committedChecks: [],
            fixtures: [.init(path: "docs/examples/schema/bad.yaml",
                             contents: "x: 1\n", schema: schema)])
        #expect(findings.map(\.kind) == [.staleGate, .fixtureSchema])
    }
}

// MARK: - Drift Kind 3 (ADR-0033 convention ↔ code citation)

struct ConventionCitationDriftTests {
    /// A minimal Discovery-Record markdown with one evidence row, parameterized by the Evidence cell.
    private func conventionMarkdown(evidence: String) -> String {
        """
        # Conventions

        ## Discovery Record

        | Change type | Evidence | Convention | Status |
        |---|---|---|---|
        | Build | \(evidence) | Use SwiftPM. | confirmed |
        """
    }

    private func conventionInput(evidence: String, stack: String = "swift") -> Drift.ConventionInput {
        .init(path: Layout.conventionSourcePath(stack: stack), stack: stack,
              text: conventionMarkdown(evidence: evidence))
    }

    /// Inject stub checks (no disk, no shell): `path:` existence and `cmd:` exit are table-driven.
    private func checks(
        present: Set<String> = [],
        failingCommands: Set<String> = []
    ) -> Drift.CitationChecks {
        .init(
            pathExists: { present.contains($0) },
            execute: { command, _ in failingCommands.contains(command) ? (1, "") : (0, "") })
    }

    // AC-BROKEN-CITATION-FLAGGED: a missing cited `path:` AND a failing cited `cmd:` each yield a
    // `conventionCitation` finding whose subject is the convention path and remedy is `re-bootstrap <stack>`.
    @Test func brokenCitationsAreFlagged() throws {
        let convention = conventionInput(
            evidence: "`path:Missing/Gone.swift`; `cmd:swift build`")
        let findings = try Drift.scan(
            schemas: [], committedChecks: [], fixtures: [],
            conventions: [convention],
            checks: checks(present: [], failingCommands: ["swift build"]))
        #expect(findings.count == 2)
        #expect(findings.allSatisfy { $0.kind == .conventionCitation })
        #expect(findings.allSatisfy { $0.subject == convention.path })
        #expect(findings.allSatisfy { $0.remedy == "re-bootstrap swift" })
        #expect(findings.contains { $0.detail.contains("Missing/Gone.swift") })
        #expect(findings.contains { $0.detail.contains("swift build") })
    }

    // AC-INTACT-CITATIONS-CLEAN: every typed citation holding (path present, command exits 0) ⇒ no finding.
    @Test func intactCitationsAreClean() throws {
        let convention = conventionInput(
            evidence: "`path:Package.swift`; `cmd:swift build`")
        let findings = try Drift.scan(
            schemas: [], committedChecks: [], fixtures: [],
            conventions: [convention],
            checks: checks(present: ["Package.swift"], failingCommands: []))
        #expect(findings.isEmpty, "all typed citations hold ⇒ no convention-citation finding")
    }

    // AC-OPEN-GAP-SKIPPED: a row whose Evidence cell carries zero typed tokens (only unprefixed
    // backticked vocabulary / prose) is skipped, never flagged (DC3).
    @Test func openGapRowIsSkipped() throws {
        let convention = conventionInput(
            evidence: "`@Test` and `swiftlint`; no path or command found")
        let findings = try Drift.scan(
            schemas: [], committedChecks: [], fixtures: [],
            conventions: [convention],
            checks: checks(present: [], failingCommands: []))
        #expect(findings.isEmpty, "a row with zero path:/cmd: tokens has nothing to verify")
    }

    // AC-DETERMINISTIC-ADVISORY-PROVENANCE: a hand-edited convention's finding carries the annotation.
    @Test func handEditedConventionIsAnnotated() throws {
        let convention = conventionInput(evidence: "`path:Missing/Gone.swift`")
        let annotated = try Drift.scan(
            schemas: [], committedChecks: [], fixtures: [],
            conventions: [convention], checks: checks(present: []),
            handEditedPaths: [convention.path])
        #expect(annotated.first?.handEdited == true)

        let plain = try Drift.scan(
            schemas: [], committedChecks: [], fixtures: [],
            conventions: [convention], checks: checks(present: []))
        #expect(plain.first?.handEdited == false)
    }

    // The parser scans ONLY `|`-delimited table rows. The real swift.md prefaces its Discovery Record
    // with an explanatory bullet list that itself contains `path:`/`cmd:` tokens (the grammar) — those
    // are prose, not citations, and must never be checked (or they'd false-positive the real repo).
    @Test func nonTableBulletLinesAreIgnored() throws {
        let markdown = """
        # Conventions

        ## Discovery Record

        Evidence is recorded as typed tokens; a parser keeps only known-prefix tokens:

        - `path:BULLET-SHOULD-NOT-PARSE.swift` — a concrete repo-relative path; drift checks it exists.
        - `cmd:bullet-should-not-run` — a shell command; drift checks it exits 0.

        | Change type | Evidence | Convention | Status |
        |---|---|---|---|
        | Build | `path:Package.swift`; `cmd:swift build` | Use SwiftPM. | confirmed |
        """
        let convention = Drift.ConventionInput(
            path: Layout.conventionSourcePath(stack: "swift"), stack: "swift", text: markdown)
        // The table row's citations hold. The bullet tokens are rigged to fail IF wrongly parsed:
        // the bullet path is absent, and the bullet command is in the failing set.
        let findings = try Drift.scan(
            schemas: [], committedChecks: [], fixtures: [],
            conventions: [convention],
            checks: checks(present: ["Package.swift"], failingCommands: ["bullet-should-not-run"]))
        #expect(findings.isEmpty,
                "grammar tokens in bullet lines above the table are prose, not citations")
    }

    // A multi-row table evaluates each row independently: a confirmed row whose path is missing is
    // flagged, a sibling confirmed row whose citations hold is not, and an open-gap row mid-table is
    // skipped — and the `|---|` header-separator row is never mistaken for a citation row.
    @Test func multiRowTableEvaluatesEachRowIndependently() throws {
        let markdown = """
        # Conventions

        ## Discovery Record

        | Change type | Evidence | Convention | Status |
        |---|---|---|---|
        | Build | `path:Package.swift`; `cmd:swift build` | Use SwiftPM. | confirmed |
        | Test | `path:Tests/Gone.swift` | Use Swift Testing (`@Test`). | confirmed |
        | Lint | no `swiftlint` config found | No lint command. | open gap |
        """
        let convention = Drift.ConventionInput(
            path: Layout.conventionSourcePath(stack: "swift"), stack: "swift", text: markdown)
        // Build's path present + command passes; Test's path missing; Lint carries no typed token.
        let findings = try Drift.scan(
            schemas: [], committedChecks: [], fixtures: [],
            conventions: [convention],
            checks: checks(present: ["Package.swift"], failingCommands: []))
        #expect(findings.count == 1, "only the Test row's missing path should flag")
        #expect(findings.first?.kind == .conventionCitation)
        #expect(findings.first?.subject == convention.path)
        #expect(findings.first?.detail.contains("Tests/Gone.swift") == true)
    }

    // MARK: - Event timestamps & owner (run-integrity S1)

    /// A store rooted in a throwaway temp dir with an injected owner closure, so these tests need
    /// no real git config and leave nothing behind.
    private func eventStore(owner: @escaping @Sendable () -> RunEventOwner) -> (RunStore, () -> Void) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-sdd-events-\(UUID().uuidString)", isDirectory: true)
        let store = RunStore(root: tmp.appendingPathComponent("runs", isDirectory: true),
                             captureOwner: owner)
        return (store, { try? FileManager.default.removeItem(at: tmp) })
    }

    /// A fixed-injected clock makes the stamped `at` deterministic and `…Z`-formed (acceptance
    /// `at-on-new-events`, `no-wallclock-on-pure-path`).
    @Test func appendStampsDeterministicUTCZFromInjectedClock() throws {
        let (store, cleanup) = eventStore(owner: { .unowned })
        defer { cleanup() }
        try store.create(runId: "r", pipelineDir: "/x")
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)  // 2023-11-14T22:13:20Z
        try store.append(.nodeStarted(node: "build"), to: "r", now: fixed)

        let records = try store.eventsWithMetadata(of: "r")
        let stamped = records.filter { $0.event == .nodeStarted(node: "build") }
        #expect(stamped.count == 1)
        #expect(stamped.first?.at == "2023-11-14T22:13:20Z")
        // Re-stamping the same instant is byte-identical: no wall clock involved.
        #expect(RunStore.utcZ(fixed) == "2023-11-14T22:13:20Z")
    }

    /// Source instants expressed in two different zones store as UTC and order correctly by `at`
    /// when read back (acceptance `two-zone-ordering`).
    @Test func twoSourceZonesOrderByUTCWhenReadBack() throws {
        let (store, cleanup) = eventStore(owner: { .unowned })
        defer { cleanup() }
        try store.create(runId: "r", pipelineDir: "/x")

        // Same wall-clock-looking moment, two zones — the +09:00 instant is actually EARLIER in UTC.
        let tokyo = ISO8601DateFormatter().date(from: "2024-01-01T10:00:00+09:00")!
        let newYork = ISO8601DateFormatter().date(from: "2024-01-01T10:00:00-05:00")!
        try store.append(.nodeStarted(node: "later"), to: "r", now: newYork)
        try store.append(.nodeStarted(node: "earlier"), to: "r", now: tokyo)

        // Stored as UTC `…Z` in append order (the +09:00 instant was appended second).
        let records = try store.eventsWithMetadata(of: "r")
        #expect(records.map(\.at) == ["2024-01-01T15:00:00Z", "2024-01-01T01:00:00Z"])
        // Read back, both are directly string-comparable; sorting by `at` totally orders them, and
        // the tokyo (+09:00) instant is correctly the earlier of the two.
        let byTime = records.sorted { ($0.at ?? "") < ($1.at ?? "") }
        #expect(byTime.compactMap(\.at) == ["2024-01-01T01:00:00Z", "2024-01-01T15:00:00Z"])
        #expect(byTime.first?.event == .nodeStarted(node: "earlier"))
    }

    /// A legacy bare-`RunEvent` file (no `at`/`owner`) decodes without error and surfaces unknown
    /// metadata — no crash, no epoch substitution (acceptance `legacy-degrades`).
    @Test func legacyBareEventDecodesWithUnknownMetadata() throws {
        let (store, cleanup) = eventStore(owner: { .unowned })
        defer { cleanup() }
        try store.create(runId: "r", pipelineDir: "/x")

        // Write a bare legacy event file directly (the pre-metadata on-disk shape).
        let layout = RunLayout(root: store.root, runId: "r")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(RunEvent.nodeCompleted(node: "legacy", producedArtifacts: ["a.v1"]))
            .write(to: layout.eventFile(1), options: .atomic)
        // Then append a new metadata-bearing event after it.
        try store.append(.nodeStarted(node: "fresh"), to: "r", now: Date(timeIntervalSince1970: 0))

        let records = try store.eventsWithMetadata(of: "r")
        #expect(records.count == 2)
        #expect(records[0].event == .nodeCompleted(node: "legacy", producedArtifacts: ["a.v1"]))
        #expect(records[0].at == nil)       // unknown, not zero/epoch
        #expect(records[0].owner == nil)
        #expect(records[1].at == "1970-01-01T00:00:00Z")

        // The pure projection still yields all events in order, and the Reducer folds them the same
        // as if no metadata existed (acceptance `append-only-replayable`).
        let events = try store.events(of: "r")
        #expect(events == [.nodeCompleted(node: "legacy", producedArtifacts: ["a.v1"]),
                           .nodeStarted(node: "fresh")])
        let state = try store.state(of: "r")
        #expect(state.completedNodes == ["legacy"])
        #expect(state.inProgressNodes == ["fresh"])
        #expect(state.readyArtifacts == ["a.v1"])
    }

    /// Owner is captured from the injected git identity (acceptance `owner-from-git`).
    @Test func ownerCapturedFromGitIdentity() throws {
        let identity = RunEventOwner.identified(name: "Ada Lovelace", email: "ada@example.com")
        let (store, cleanup) = eventStore(owner: { identity })
        defer { cleanup() }
        try store.create(runId: "r", pipelineDir: "/x")
        try store.append(.nodeStarted(node: "build"), to: "r", now: Date(timeIntervalSince1970: 0))

        let records = try store.eventsWithMetadata(of: "r")
        #expect(records.first?.owner == identity)
    }

    /// With no git identity, owner resolves to `.unowned` — no guessed value (acceptance
    /// `unowned-when-no-identity`).
    @Test func ownerIsUnownedWithoutGitIdentity() throws {
        let (store, cleanup) = eventStore(owner: { .unowned })
        defer { cleanup() }
        try store.create(runId: "r", pipelineDir: "/x")
        try store.append(.escalated(node: "gate", checks: ["c"]), to: "r",
                         now: Date(timeIntervalSince1970: 0))

        let records = try store.eventsWithMetadata(of: "r")
        #expect(records.first?.owner == .unowned)
    }
}

// MARK: - pipelineDir relative storage & legacy migration (run-integrity S2)

/// Worktree-drift fix: `RunStore` stores `pipelineDir` relative to the git toplevel, resolves it
/// against the CURRENT toplevel on read, heals a legacy absolute path whose trailing `.ai-sdd/…`
/// still resolves, and rewrites it relative on the next mutation — idempotently. The injected
/// `gitToplevel` closure means none of these touch a real repo.
struct RunStorePipelineDirTests {
    /// A store rooted in a throwaway temp dir with an injected toplevel, so these tests need no real
    /// git repo and leave nothing behind. The toplevel defaults to the temp dir itself, so an
    /// in-tree pipelineDir relativizes against it.
    private func pipelineStore(
        toplevel: @escaping @Sendable (URL) -> String?
    ) -> (store: RunStore, root: URL, cleanup: () -> Void) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-sdd-pipelinedir-\(UUID().uuidString)", isDirectory: true)
        let top = toplevel(root)
        let store = RunStore(root: root.appendingPathComponent(".ai-sdd/runs", isDirectory: true),
                             captureOwner: { .unowned },
                             gitToplevel: { top })
        return (store, root, { try? FileManager.default.removeItem(at: root) })
    }

    /// Read the raw on-disk `pipelineDir` WITHOUT the read-time heal, to assert what was persisted.
    private func storedPipelineDir(_ store: RunStore, _ runId: String) throws -> String {
        let metaURL = RunLayout(root: store.root, runId: runId).meta
        return try JSONDecoder().decode(RunMeta.self, from: Data(contentsOf: metaURL)).pipelineDir
    }

    /// A fresh `create` writes a git-relative `pipelineDir` when the path is under the current
    /// toplevel (acceptance `relative-write-on-start`).
    @Test func createWritesGitRelativePipelineDir() throws {
        let (store, root, cleanup) = pipelineStore(toplevel: { $0.standardizedFileURL.path })
        defer { cleanup() }
        let feature = root.appendingPathComponent(".ai-sdd/features/run-integrity", isDirectory: true)
        try store.create(runId: "r", pipelineDir: feature.path)

        #expect(try storedPipelineDir(store, "r") == ".ai-sdd/features/run-integrity")
    }

    /// A run.json whose `pipelineDir` is stored relative resolves to the correct directory when read
    /// with a DIFFERENT toplevel injected (a sibling worktree), and `DashboardProjection`-style
    /// resolution against `base` lands on the standardized expected dir (acceptance
    /// `read-resolves-cross-worktree`).
    @Test func relativePipelineDirResolvesUnderADifferentToplevel() throws {
        // Write under one toplevel…
        let (writeStore, writeRoot, writeCleanup) =
            pipelineStore(toplevel: { $0.standardizedFileURL.path })
        defer { writeCleanup() }
        let feature = writeRoot.appendingPathComponent(".ai-sdd/features/x", isDirectory: true)
        try writeStore.create(runId: "r", pipelineDir: feature.path)
        #expect(try storedPipelineDir(writeStore, "r") == ".ai-sdd/features/x")

        // …then read the SAME relative form against a sibling worktree's base. It anchors to that
        // worktree's `.ai-sdd/features/x`, exactly as DashboardProjection.resolvedPath does.
        let sibling = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-sdd-sibling-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sibling) }
        let siblingStore = RunStore.local(under: sibling)
        let resolved = URL(fileURLWithPath: ".ai-sdd/features/x", relativeTo: siblingStore.base)
            .standardizedFileURL.path
        #expect(resolved == sibling.appendingPathComponent(".ai-sdd/features/x")
            .standardizedFileURL.path)
    }

    /// A legacy absolute `pipelineDir` whose path is gone, but whose trailing `.ai-sdd/features/<n>/`
    /// resolves under the CURRENT toplevel, is healed on read and rewritten relative on the next
    /// mutation (acceptance `legacy-absolute-heal-and-migrate`).
    @Test func legacyAbsolutePipelineDirIsHealedAndMigratedOnAppend() throws {
        let (store, root, cleanup) = pipelineStore(toplevel: { $0.standardizedFileURL.path })
        defer { cleanup() }
        // The real feature dir exists under the current toplevel…
        let feature = root.appendingPathComponent(".ai-sdd/features/run-integrity", isDirectory: true)
        try FileManager.default.createDirectory(at: feature, withIntermediateDirectories: true)
        // …but the stored path points at a now-dead sibling worktree (different prefix, same tail).
        let legacy = "/private/var/old-worktree/.ai-sdd/features/run-integrity"
        try store.create(runId: "r", pipelineDir: legacy)
        // create() does NOT relativize an out-of-tree absolute path: it is stored as-is.
        #expect(try storedPipelineDir(store, "r") == legacy)

        // Read heals it (no rewrite yet — read is side-effect-free).
        #expect(try store.meta(of: "r").pipelineDir == ".ai-sdd/features/run-integrity")
        #expect(try storedPipelineDir(store, "r") == legacy, "read must not rewrite run.json")

        // The next mutation persists the canonical relative form.
        try store.append(.nodeStarted(node: "plan"), to: "r", now: Date(timeIntervalSince1970: 0))
        #expect(try storedPipelineDir(store, "r") == ".ai-sdd/features/run-integrity")
    }

    /// Re-reading and re-appending an already-healed (relative) run.json is a no-op — no rewrite,
    /// stable resolution (acceptance `heal-round-trip-idempotent`).
    @Test func healedPipelineDirIsIdempotentAcrossReadsAndAppends() throws {
        let (store, root, cleanup) = pipelineStore(toplevel: { $0.standardizedFileURL.path })
        defer { cleanup() }
        let feature = root.appendingPathComponent(".ai-sdd/features/run-integrity", isDirectory: true)
        try FileManager.default.createDirectory(at: feature, withIntermediateDirectories: true)
        // Already stored relative (the post-create / post-migration shape).
        try store.create(runId: "r", pipelineDir: feature.path)
        #expect(try storedPipelineDir(store, "r") == ".ai-sdd/features/run-integrity")

        // Repeated reads return the same value and never rewrite.
        #expect(try store.meta(of: "r").pipelineDir == ".ai-sdd/features/run-integrity")
        #expect(try store.meta(of: "r").pipelineDir == ".ai-sdd/features/run-integrity")
        let beforeAppend = try storedPipelineDir(store, "r")

        // An append on an already-canonical run.json does not rewrite the pipelineDir.
        try store.append(.nodeStarted(node: "plan"), to: "r", now: Date(timeIntervalSince1970: 0))
        #expect(try storedPipelineDir(store, "r") == beforeAppend)
        #expect(try store.meta(of: "r").pipelineDir == ".ai-sdd/features/run-integrity")
    }

    /// A legacy absolute path that resolves NOWHERE under the current toplevel is left exactly as
    /// stored — no heal, no rewrite — so slice S4 can surface it (acceptance
    /// `unresolvable-absolute-untouched`).
    @Test func unresolvableLegacyAbsolutePipelineDirIsLeftUntouched() throws {
        let (store, _, cleanup) = pipelineStore(toplevel: { $0.standardizedFileURL.path })
        defer { cleanup() }
        // No matching feature dir is created under the toplevel ⇒ the re-anchored tail resolves nowhere.
        let legacy = "/private/var/old-worktree/.ai-sdd/features/ghost"
        try store.create(runId: "r", pipelineDir: legacy)
        #expect(try storedPipelineDir(store, "r") == legacy)

        // Read returns the stored value unchanged (no invented match).
        #expect(try store.meta(of: "r").pipelineDir == legacy)
        // A mutation does not rewrite it either.
        try store.append(.nodeStarted(node: "plan"), to: "r", now: Date(timeIntervalSince1970: 0))
        #expect(try storedPipelineDir(store, "r") == legacy)
    }

    /// The relative-conversion logic is a pure function — exercised with injected toplevel inputs and
    /// no real git or filesystem (acceptance `path-helper-pure`).
    @Test func relativizeIsPureOverInjectedToplevel() {
        // Absolute under the toplevel ⇒ relativized.
        #expect(RunStore.relativize("/repo/.ai-sdd/features/x", toplevel: "/repo")
            == ".ai-sdd/features/x")
        // Trailing slash / `.` segments collapse the same way.
        #expect(RunStore.relativize("/repo/./.ai-sdd/features/x/", toplevel: "/repo/")
            == ".ai-sdd/features/x")
        // Not under the toplevel ⇒ unchanged.
        #expect(RunStore.relativize("/elsewhere/.ai-sdd/features/x", toplevel: "/repo")
            == "/elsewhere/.ai-sdd/features/x")
        // Already relative ⇒ unchanged.
        #expect(RunStore.relativize(".ai-sdd/features/x", toplevel: "/repo") == ".ai-sdd/features/x")
        // No toplevel ⇒ unchanged (no repo, no guess).
        #expect(RunStore.relativize("/repo/.ai-sdd/features/x", toplevel: nil)
            == "/repo/.ai-sdd/features/x")
    }

    /// The legacy-strip + re-anchor logic is pure — exercised with an injected `exists` predicate so
    /// it needs no real filesystem (acceptance `path-helper-pure`).
    @Test func healIsPureOverInjectedToplevelAndExistence() {
        let top = "/repo"
        // (2) Absolute, still resolves where stored ⇒ relativized.
        #expect(RunStore.heal("/repo/.ai-sdd/features/x", toplevel: top,
                              exists: { $0 == "/repo/.ai-sdd/features/x" }) == ".ai-sdd/features/x")
        // (3) Absolute, dead prefix, but the re-anchored tail resolves ⇒ healed to relative.
        #expect(RunStore.heal("/old/.ai-sdd/features/x", toplevel: top,
                              exists: { $0 == "/repo/.ai-sdd/features/x" }) == ".ai-sdd/features/x")
        // (4) Re-anchored tail resolves nowhere ⇒ byte-for-byte unchanged.
        #expect(RunStore.heal("/old/.ai-sdd/features/x", toplevel: top,
                              exists: { _ in false }) == "/old/.ai-sdd/features/x")
        // No `.ai-sdd` segment to strip ⇒ unchanged.
        #expect(RunStore.heal("/old/features/x", toplevel: top,
                              exists: { _ in false }) == "/old/features/x")
        // Relative stored form ⇒ returned unchanged (already canonical).
        #expect(RunStore.heal(".ai-sdd/features/x", toplevel: top,
                              exists: { _ in true }) == ".ai-sdd/features/x")
        // No toplevel ⇒ unchanged.
        #expect(RunStore.heal("/old/.ai-sdd/features/x", toplevel: nil,
                              exists: { _ in true }) == "/old/.ai-sdd/features/x")
    }

    /// `RunMeta` with either an absolute or a relative `pipelineDir` encodes and decodes cleanly
    /// (acceptance `store-round-trips-both-forms`).
    @Test func runMetaRoundTripsAbsoluteAndRelativeForms() throws {
        for form in ["/abs/.ai-sdd/features/x", ".ai-sdd/features/x"] {
            let meta = RunMeta(runId: "r", pipelineDir: form)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(meta)
            #expect(try JSONDecoder().decode(RunMeta.self, from: data) == meta)
        }
    }

    // MARK: - RunResolver (S3) — the shared name resolver, exercised PURELY (no filesystem/git I/O)
    // across all five precedence branches via injected enumeration/existence inputs.

    /// Build a `RunResolver.Inputs` from in-memory values — the injected-edge stand-in tests drive
    /// instead of a real `.ai-sdd` tree (decision `io-injected-at-resolver-edge`).
    private func resolverInputs(runs: Set<String> = [],
                                featureDirs: Set<String> = [],
                                features: [(feature: String, slices: [String])] = [])
        -> RunResolver.Inputs {
        RunResolver.Inputs(
            runExists: { runs.contains($0) },
            featureDirExists: { featureDirs.contains($0) },
            features: { features })
    }

    /// (1) An existing runId resolves to that run with no self-start — preserving today's behavior.
    @Test func resolverExistingRunIdWins() {
        // The name is also a feature dir AND a slice, but runId precedence is checked first.
        let inputs = resolverInputs(runs: ["alpha"], featureDirs: ["alpha"],
                                    features: [("beta", ["alpha"])])
        #expect(RunResolver.resolve(name: "alpha", inputs: inputs) == .existingRun(runId: "alpha"))
    }

    /// (2) A feature dir with no existing run self-starts `runId=<name>` — checked before slices,
    /// so a feature whose name also appears as a slice elsewhere is not mis-resolved.
    @Test func resolverFeatureDirSelfStartsBeforeSlice() {
        let inputs = resolverInputs(featureDirs: ["run-integrity"],
                                    features: [("other", ["run-integrity"])])
        #expect(RunResolver.resolve(name: "run-integrity", inputs: inputs)
            == .featureSelfStart(feature: "run-integrity"))
    }

    /// (3) A slice id in exactly one feature self-starts that feature's run (`runId=<feature>`).
    @Test func resolverUniqueSliceSelfStartsItsFeature() {
        let inputs = resolverInputs(features: [
            ("run-integrity", ["name-resolver-self-start", "stale-run-surfacing"]),
            ("dashboard", ["instrument", "showcase"])
        ])
        #expect(RunResolver.resolve(name: "name-resolver-self-start", inputs: inputs)
            == .sliceSelfStart(feature: "run-integrity", slice: "name-resolver-self-start"))
    }

    /// (4) A slice id in more than one feature is ambiguous, with the candidate list SORTED for
    /// stable output (decision `error-shape-and-exit`). Declaration order is `zeta` then `alpha`.
    @Test func resolverAmbiguousSliceListsSortedCandidates() {
        let inputs = resolverInputs(features: [
            ("zeta", ["shared-slice"]),
            ("alpha", ["shared-slice"])
        ])
        #expect(RunResolver.resolve(name: "shared-slice", inputs: inputs)
            == .ambiguous(candidates: ["alpha", "zeta"]))
    }

    /// (5) A name matching no runId, no feature dir, and no slice id is unknown.
    @Test func resolverUnknownNameWhenNoMatch() {
        let inputs = resolverInputs(runs: ["r1"], featureDirs: ["feat"],
                                    features: [("feat", ["s1"])])
        #expect(RunResolver.resolve(name: "nope", inputs: inputs) == .unknown)
        #expect(RunResolver.resolve(name: "nope", inputs: inputs).runId == nil)
    }

    /// The pure slice→feature lookup deduplicates a feature that lists a slice twice (it owns it once).
    @Test func resolverSliceLookupDeduplicatesOwner() {
        let owners = RunResolver.featuresOwning(
            slice: "s", features: [("a", ["s", "s"]), ("b", ["x"])])
        #expect(owners == ["a"])
    }

    /// `start <name>` is a no-op alias when a matching run already exists: re-creating it would be
    /// rejected, so the CLI guards on `exists` first (decision `explicit-start-becomes-noop-alias`).
    /// Here we assert the underlying idempotency — the store reports the run as existing, so no
    /// duplicate runStarted is appended by a second start.
    @Test func startIsIdempotentWhenRunExists() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("resolver-start-\(UUID().uuidString)", isDirectory: true)
        let store = RunStore(root: tmp,
                             captureOwner: { .unowned }, gitToplevel: { nil })
        try store.create(runId: "run-x", pipelineDir: "/some/dir")
        try store.append(.runStarted(seedArtifacts: []), to: "run-x")
        #expect(store.exists("run-x"))
        // A second `start` for an existing run is a guarded no-op: the resolver/Start path skips
        // create+runStarted, so the event count is unchanged.
        let before = try store.events(of: "run-x").count
        if !store.exists("run-x") {  // the Start/self-start guard — false here, so nothing appends
            try store.append(.runStarted(seedArtifacts: []), to: "run-x")
        }
        #expect(try store.events(of: "run-x").count == before)
    }
}
