import Foundation
import SDDModels

public final class OpenSpecArtifactStore {
    private let workspace: SDDWorkspaceConfiguration
    private let fileManager: FileManager

    private let artifactDefinitions: [(type: String, file: String, required: Bool, description: String)] = [
        ("openspec_proposal", "proposal.md", true, "Product intent and feature proposal."),
        ("openspec_design", "design.md", true, "Decision-closed design and implementation plan."),
        ("openspec_tasks", "tasks.md", true, "Implementation checklist."),
        ("openspec_review", "review.md", true, "Review verdict and findings."),
        ("openspec_decisions", "decisions.md", true, "Closed decisions attached to the change."),
        ("openspec_run_summary", "run-summary.json", true, "Compact run summary for audit and telemetry correlation.")
    ]

    public init(workspace: SDDWorkspaceConfiguration, fileManager: FileManager = .default) {
        self.workspace = workspace
        self.fileManager = fileManager
    }

    public func createFeatureArtifacts(featureSlug: String, intake: NormalizedIntake? = nil) throws {
        let root = changeRoot(featureSlug: featureSlug)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let templates: [(String, String)] = [
            ("proposal.md", intake.map(renderProposal) ?? "# Proposal\n\n## Intent\n\n_To be completed._\n"),
            ("design.md", "# Design\n\n## Plan\n\n_To be completed by the planning action._\n"),
            ("tasks.md", "# Tasks\n\n- [ ] To be completed by the planning action.\n"),
            ("review.md", "# Review\n\n## Verdict\n\n_To be completed by the review action._\n"),
            ("decisions.md", intake.map(renderDecisions) ?? "# Decisions\n\n_No closed decisions recorded yet._\n")
        ]

        for (name, content) in templates {
            let url = root.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: url.path) {
                try content.data(using: .utf8)?.write(to: url)
            }
        }
    }

    public func artifactRefs(featureSlug: String) -> [ArtifactRef] {
        artifactDefinitions.map { definition in
            ArtifactRef(type: definition.type, path: relativePath(featureSlug: featureSlug, file: definition.file))
        }
    }

    public func artifactDescriptors(featureSlug: String) -> [ArtifactDescriptor] {
        artifactDefinitions.map { definition in
            ArtifactDescriptor(
                ref: ArtifactRef(type: definition.type, path: relativePath(featureSlug: featureSlug, file: definition.file)),
                required: definition.required,
                description: definition.description
            )
        }
    }

    public func readArtifact(featureSlug: String, type: String) throws -> ArtifactContent {
        guard let descriptor = artifactDescriptors(featureSlug: featureSlug).first(where: { $0.ref.type == type }) else {
            throw SDDCoreError.artifactNotFound(type)
        }

        let url = workspace.root.appendingPathComponent(descriptor.ref.path)
        guard fileManager.fileExists(atPath: url.path) else {
            throw SDDCoreError.artifactNotFound(descriptor.ref.path)
        }

        let data = try Data(contentsOf: url)
        guard let content = String(data: data, encoding: .utf8) else {
            throw SDDCoreError.artifactReadFailed(descriptor.ref.path)
        }

        return ArtifactContent(ref: descriptor.ref, content: content, byteCount: data.count)
    }

    public func validateArtifacts(featureSlug: String) -> ArtifactValidationReport {
        let statuses = artifactDescriptors(featureSlug: featureSlug).map { descriptor in
            artifactStatus(for: descriptor)
        }
        let issues = statuses.compactMap { status -> ArtifactValidationIssue? in
            switch status.state {
            case .missing:
                return ArtifactValidationIssue(
                    ref: status.ref,
                    reason: .missing,
                    message: "Required OpenSpec artifact is missing."
                )
            case .empty:
                return ArtifactValidationIssue(
                    ref: status.ref,
                    reason: .empty,
                    message: "Required OpenSpec artifact is empty."
                )
            case .placeholder:
                return ArtifactValidationIssue(
                    ref: status.ref,
                    reason: .placeholder,
                    message: "Required OpenSpec artifact still contains scaffold placeholder content."
                )
            case .ready:
                return nil
            }
        }

        return ArtifactValidationReport(
            featureSlug: featureSlug,
            valid: issues.isEmpty,
            artifacts: statuses,
            issues: issues
        )
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

    private func artifactStatus(for descriptor: ArtifactDescriptor) -> ArtifactStatus {
        let url = workspace.root.appendingPathComponent(descriptor.ref.path)
        guard fileManager.fileExists(atPath: url.path) else {
            return ArtifactStatus(ref: descriptor.ref, required: descriptor.required, state: .missing, byteCount: nil)
        }

        guard let data = try? Data(contentsOf: url) else {
            return ArtifactStatus(ref: descriptor.ref, required: descriptor.required, state: .missing, byteCount: nil)
        }

        guard let content = String(data: data, encoding: .utf8) else {
            return ArtifactStatus(ref: descriptor.ref, required: descriptor.required, state: .empty, byteCount: data.count)
        }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return ArtifactStatus(ref: descriptor.ref, required: descriptor.required, state: .empty, byteCount: data.count)
        }

        if containsScaffoldPlaceholder(trimmed) {
            return ArtifactStatus(ref: descriptor.ref, required: descriptor.required, state: .placeholder, byteCount: data.count)
        }

        return ArtifactStatus(ref: descriptor.ref, required: descriptor.required, state: .ready, byteCount: data.count)
    }

    private func containsScaffoldPlaceholder(_ content: String) -> Bool {
        content.contains("_To be completed") ||
            content.contains("- [ ] To be completed") ||
            content.contains("_No closed decisions recorded yet._")
    }

    private func renderProposal(_ intake: NormalizedIntake) -> String {
        let featureLines = intake.featureCatalog.map { feature in
            "- `\(feature.featureSlug)` - \(feature.title): \(feature.description)"
        }.joined(separator: "\n")
        let stackLines = intake.stackAssignments.map { assignment in
            "- `\(assignment.featureSlug)` -> `\(assignment.stack)`"
        }.joined(separator: "\n")
        let requirementLines = intake.sliceReadyRequirements.map { requirement in
            """
            ## Slice Requirement: \(requirement.title)

            Feature slug: `\(requirement.featureSlug)`

            Acceptance surface: `\(requirement.acceptanceSurface.rawValue)`

            Alternatives required: `\(requirement.alternativesRequired)`

            \(requirement.body)
            """
        }.joined(separator: "\n\n")

        return """
        # Proposal

        ## Intake

        Type: `\(intake.intakeType.rawValue)`

        Title: \(intake.title)

        Source ID: \(intake.sourceId ?? "none")

        Owner: \(intake.owner ?? "none")

        ## Product Intent

        \(intake.productIntent)

        ## Feature Catalog

        \(featureLines.isEmpty ? "No features normalized." : featureLines)

        ## Stack Assignment

        \(stackLines.isEmpty ? "No stack assignments normalized." : stackLines)

        \(requirementLines)
        """
    }

    private func renderDecisions(_ intake: NormalizedIntake) -> String {
        if intake.closedDecisions.isEmpty {
            return """
            # Decisions

            No closed decisions recorded for this intake.
            """
        }

        let decisions = intake.closedDecisions.map { "- \($0)" }.joined(separator: "\n")
        return """
        # Decisions

        \(decisions)
        """
    }
}
