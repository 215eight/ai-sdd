import Foundation
import SDDModels

public final class OpenSpecArtifactStore {
    private let workspace: SDDWorkspaceConfiguration
    private let fileManager: FileManager

    public init(workspace: SDDWorkspaceConfiguration, fileManager: FileManager = .default) {
        self.workspace = workspace
        self.fileManager = fileManager
    }

    public func createFeatureArtifacts(featureSlug: String) throws {
        let root = changeRoot(featureSlug: featureSlug)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let templates: [(String, String)] = [
            ("proposal.md", "# Proposal\n\n## Intent\n\n_To be completed._\n"),
            ("design.md", "# Design\n\n## Plan\n\n_To be completed by the planning action._\n"),
            ("tasks.md", "# Tasks\n\n- [ ] To be completed by the planning action.\n"),
            ("review.md", "# Review\n\n## Verdict\n\n_To be completed by the review action._\n"),
            ("decisions.md", "# Decisions\n\n_No closed decisions recorded yet._\n")
        ]

        for (name, content) in templates {
            let url = root.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: url.path) {
                try content.data(using: .utf8)?.write(to: url)
            }
        }
    }

    public func artifactRefs(featureSlug: String) -> [ArtifactRef] {
        [
            ArtifactRef(type: "openspec_proposal", path: relativePath(featureSlug: featureSlug, file: "proposal.md")),
            ArtifactRef(type: "openspec_design", path: relativePath(featureSlug: featureSlug, file: "design.md")),
            ArtifactRef(type: "openspec_tasks", path: relativePath(featureSlug: featureSlug, file: "tasks.md")),
            ArtifactRef(type: "openspec_review", path: relativePath(featureSlug: featureSlug, file: "review.md")),
            ArtifactRef(type: "openspec_decisions", path: relativePath(featureSlug: featureSlug, file: "decisions.md")),
            ArtifactRef(type: "openspec_run_summary", path: relativePath(featureSlug: featureSlug, file: "run-summary.json"))
        ]
    }

    public func writeRunSummary(_ summary: RunSummary) throws {
        let root = changeRoot(featureSlug: summary.featureSlug)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try SDDJSON.encoder().encode(summary)
        try data.write(to: root.appendingPathComponent("run-summary.json"), options: .atomic)
    }

    public func findRunSummary(runId: String) throws -> RunSummary {
        let changesRoot = workspace.openspecRoot.appendingPathComponent("changes")
        guard fileManager.fileExists(atPath: changesRoot.path) else {
            throw SDDCoreError.runNotFound(runId)
        }

        let entries = try fileManager.contentsOfDirectory(
            at: changesRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        for entry in entries {
            let summaryURL = entry.appendingPathComponent("run-summary.json")
            guard fileManager.fileExists(atPath: summaryURL.path) else {
                continue
            }
            let data = try Data(contentsOf: summaryURL)
            let summary = try SDDJSON.decoder().decode(RunSummary.self, from: data)
            if summary.runId == runId {
                return summary
            }
        }

        throw SDDCoreError.runNotFound(runId)
    }

    private func changeRoot(featureSlug: String) -> URL {
        workspace.openspecRoot
            .appendingPathComponent("changes")
            .appendingPathComponent(featureSlug)
    }

    private func relativePath(featureSlug: String, file: String) -> String {
        "openspec/changes/\(featureSlug)/\(file)"
    }
}
