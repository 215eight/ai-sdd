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
