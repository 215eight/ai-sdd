import Foundation
import ArgumentParser
import FactoryModels
import FactoryEngine

// The CLI the agent drives (Mode B). The engine is the deterministic planner; the LLM does
// the work via skills. This first slice exposes `validate`; `start` / `next` / `submit` follow.
@main
struct Factory: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "factory",
        abstract: "Spec-driven software factory engine (deterministic planner; agents do the work via skills).",
        subcommands: [Validate.self]
    )
}

struct Validate: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Load a Pipeline + its Workers from <dir> and check the wiring (referential + edge type-check)."
    )

    @Argument(help: "Directory containing pipeline.yaml and a workers/ folder.")
    var dir: String

    func run() throws {
        let loader = SpecLoader()
        let base = URL(fileURLWithPath: dir, isDirectory: true)

        let pipelineEnv = try loader.loadPipelineYAML(
            try String(contentsOf: base.appendingPathComponent("pipeline.yaml"), encoding: .utf8)
        )
        let pipeline = pipelineEnv.spec

        var workers: [String: WorkerSpec] = [:]
        let workersDir = base.appendingPathComponent("workers")
        let files = (try? FileManager.default.contentsOfDirectory(
            at: workersDir, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "yaml" {
            let env = try loader.loadWorkerYAML(try String(contentsOf: file, encoding: .utf8))
            workers[env.metadata.name] = env.spec
        }

        let issues = SpecValidator.validate(pipeline: pipeline, workers: workers)
        guard issues.isEmpty else {
            for issue in issues {
                FileHandle.standardError.write(Data("✗ [\(issue.kind.rawValue)] \(issue.message)\n".utf8))
            }
            throw ExitCode.failure
        }
        print("✓ \(pipelineEnv.metadata.name): valid — \(pipeline.nodes.count) nodes, "
            + "\(pipeline.edges.count) edges, \(workers.count) workers")
    }
}
