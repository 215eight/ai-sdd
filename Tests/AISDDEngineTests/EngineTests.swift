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
}

private extension SpecLoadError {
    var isSyntax: Bool { if case .syntax = self { return true } else { return false } }
    var isSchema: Bool { if case .schema = self { return true } else { return false } }
}
