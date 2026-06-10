import XCTest
import FactoryModels
@testable import FactoryEngine

final class EngineTests: XCTestCase {
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

    // Decode the envelope + flow specs, and assert the wiring type-checks cleanly.
    func testLoadAndValidate() throws {
        let pipeline = try loadPipeline()
        XCTAssertEqual(pipeline.nodes.count, 4)
        XCTAssertEqual(pipeline.edges.count, 3)

        let issues = SpecValidator.validate(pipeline: pipeline, workers: try loadWorkers())
        XCTAssertEqual(issues, [], "expected a clean pipeline, got: \(issues)")
    }

    // The DAG resolves: readiness advances as nodes complete, with parallel branches.
    func testRunnableProgression() throws {
        let pipeline = try loadPipeline()
        var state = RunState()

        // architect is the only source.
        XCTAssertEqual(Set(Scheduler.runnable(state, pipeline)), ["architect"])

        // architect completes → plan.v1 ready → migrate AND config become runnable (parallel).
        state = Reducer.reduce(state, .nodeCompleted(node: "architect", producedArtifacts: ["plan.v1"]))
        XCTAssertEqual(Set(Scheduler.runnable(state, pipeline)), ["migrate", "config"])

        // migrate completes → sql-migration.v1 ready → api runnable; config still pending.
        state = Reducer.reduce(state, .nodeCompleted(node: "migrate", producedArtifacts: ["sql-migration.v1"]))
        XCTAssertEqual(Set(Scheduler.runnable(state, pipeline)), ["config", "api"])
    }

    // A mis-wired edge fails at load (architecture.md §5).
    func testEdgeTypeMismatchIsCaught() throws {
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
        XCTAssertTrue(issues.contains { $0.kind == .edgeTypeMismatch },
                      "expected an edgeTypeMismatch, got: \(issues)")
    }

    // The reducer is a pure fold: same events ⇒ same state.
    func testReducerIsAPureFold() throws {
        let events: [RunEvent] = [
            .nodeCompleted(node: "architect", producedArtifacts: ["plan.v1"]),
            .nodeCompleted(node: "migrate", producedArtifacts: ["sql-migration.v1"])
        ]
        let a = Reducer.reduce(RunState(), events: events)
        let b = Reducer.reduce(RunState(), events: events)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.completedNodes, ["architect", "migrate"])
        XCTAssertEqual(a.readyArtifacts, ["plan.v1", "sql-migration.v1"])
    }
}
