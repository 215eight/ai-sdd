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
}
