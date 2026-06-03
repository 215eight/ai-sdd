import Foundation
import SDDCore
import SDDModels
import XCTest

final class SDDCoreTests: XCTestCase {
    func testStartRunCreatesOpenSpecArtifactsAndPlanAction() throws {
        let workspace = try temporaryWorkspace()
        let core = SDDCore(workspace: workspace)

        let result = try core.startRun(featureSlug: "checkout-flow", adapter: .codex, owner: "tester")

        XCTAssertEqual(result.status, .actionRequired)
        XCTAssertEqual(result.phase, .plan)
        XCTAssertEqual(result.action?.kind, .produceArtifact)
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.root.appendingPathComponent("openspec/changes/checkout-flow/proposal.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.root.appendingPathComponent("openspec/changes/checkout-flow/run-summary.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.root.appendingPathComponent(".sdd/telemetry/events.jsonl").path))
    }

    func testSubmitPlanRequiresApprovalAndApproveMovesToImplement() throws {
        let workspace = try temporaryWorkspace()
        let core = SDDCore(workspace: workspace)
        let started = try core.startRun(featureSlug: "checkout-flow", adapter: .codex, owner: "tester")

        let submitted = try core.submitResult(
            runId: started.runId,
            phase: .plan,
            result: ExecutionAdapterResult(
                adapter: .codex,
                status: .ok,
                artifactRefs: [],
                logRef: nil,
                telemetryRefs: [],
                tokenUsage: nil,
                error: nil
            )
        )

        XCTAssertEqual(submitted.status, .approvalRequired)
        XCTAssertEqual(submitted.action?.kind, .requestApproval)

        let approved = try core.approveGate(runId: started.runId, phase: .plan, approvedBy: "tester")

        XCTAssertEqual(approved.status, .actionRequired)
        XCTAssertEqual(approved.phase, .implement)
        XCTAssertEqual(approved.action?.kind, .executeTasks)
    }

    func testSubmitImplementMovesToReviewAndSubmitReviewCompletes() throws {
        let workspace = try temporaryWorkspace()
        let core = SDDCore(workspace: workspace)
        let started = try core.startRun(featureSlug: "checkout-flow", adapter: .claudeCode, owner: "tester")

        _ = try core.submitResult(runId: started.runId, phase: .plan, result: okResult(adapter: .claudeCode))
        _ = try core.approveGate(runId: started.runId, phase: .plan, approvedBy: "tester")

        let review = try core.submitResult(runId: started.runId, phase: .implement, result: okResult(adapter: .claudeCode))
        XCTAssertEqual(review.status, .actionRequired)
        XCTAssertEqual(review.phase, .review)
        XCTAssertEqual(review.action?.kind, .reviewChanges)

        let completed = try core.submitResult(runId: started.runId, phase: .review, result: okResult(adapter: .claudeCode))
        XCTAssertEqual(completed.status, .completed)
        XCTAssertNil(completed.action)
    }

    func testCapabilitiesExposeMVPCLIOnly() {
        let core = SDDCore(workspace: SDDWorkspaceConfiguration(root: URL(fileURLWithPath: NSTemporaryDirectory())))

        let capabilities = core.capabilities()

        XCTAssertEqual(capabilities.supportedInterfaceModes, [.cli])
        XCTAssertTrue(capabilities.supportedOperations.contains("get_next_action"))
        XCTAssertTrue(capabilities.supportedCommands.contains("submit-result"))
        XCTAssertTrue(capabilities.supportedOperations.contains("validate_artifacts"))
        XCTAssertTrue(capabilities.supportedCommands.contains("validate-artifacts"))
        XCTAssertTrue(capabilities.supportedOperations.contains("normalize_intake"))
        XCTAssertTrue(capabilities.supportedCommands.contains("normalize-intake"))
    }

    func testArtifactOperationsExposeCanonicalOpenSpecChangeArtifacts() throws {
        let workspace = try temporaryWorkspace()
        let core = SDDCore(workspace: workspace)

        _ = try core.startRun(featureSlug: "checkout-flow", adapter: .codex, owner: "tester")

        let descriptors = try core.listArtifacts(featureSlug: "checkout-flow")
        XCTAssertEqual(descriptors.map(\.ref.type), [
            "openspec_proposal",
            "openspec_design",
            "openspec_tasks",
            "openspec_review",
            "openspec_decisions",
            "openspec_run_summary"
        ])
        XCTAssertEqual(descriptors.map(\.ref.path), [
            "openspec/changes/checkout-flow/proposal.md",
            "openspec/changes/checkout-flow/design.md",
            "openspec/changes/checkout-flow/tasks.md",
            "openspec/changes/checkout-flow/review.md",
            "openspec/changes/checkout-flow/decisions.md",
            "openspec/changes/checkout-flow/run-summary.json"
        ])

        let proposal = try core.getArtifact(featureSlug: "checkout-flow", type: "openspec_proposal")
        XCTAssertEqual(proposal.ref.path, "openspec/changes/checkout-flow/proposal.md")
        XCTAssertTrue(proposal.content.contains("# Proposal"))
        XCTAssertGreaterThan(proposal.byteCount, 0)
    }

    func testValidateArtifactsReportsPlaceholdersAndMissingFiles() throws {
        let workspace = try temporaryWorkspace()
        let core = SDDCore(workspace: workspace)

        let missingReport = try core.validateArtifacts(featureSlug: "checkout-flow")
        XCTAssertFalse(missingReport.valid)
        XCTAssertEqual(missingReport.issues.count, 6)
        XCTAssertTrue(missingReport.issues.allSatisfy { $0.reason == .missing })

        _ = try core.startRun(featureSlug: "checkout-flow", adapter: .codex, owner: "tester")

        let placeholderReport = try core.validateArtifacts(featureSlug: "checkout-flow")
        XCTAssertFalse(placeholderReport.valid)
        XCTAssertEqual(placeholderReport.issues.map(\.reason), [
            .placeholder,
            .placeholder,
            .placeholder,
            .placeholder,
            .placeholder
        ])
        XCTAssertEqual(
            placeholderReport.artifacts.first(where: { $0.ref.type == "openspec_run_summary" })?.state,
            .ready
        )
    }

    func testValidateArtifactsPassesWhenCanonicalArtifactsArePopulated() throws {
        let workspace = try temporaryWorkspace()
        let core = SDDCore(workspace: workspace)

        _ = try core.startRun(featureSlug: "checkout-flow", adapter: .codex, owner: "tester")
        try writeArtifact(workspace: workspace, path: "openspec/changes/checkout-flow/proposal.md", content: "# Proposal\n\n## Intent\n\nShip checkout.\n")
        try writeArtifact(workspace: workspace, path: "openspec/changes/checkout-flow/design.md", content: "# Design\n\nUse the payment service boundary.\n")
        try writeArtifact(workspace: workspace, path: "openspec/changes/checkout-flow/tasks.md", content: "# Tasks\n\n- [x] Define payment adapter.\n")
        try writeArtifact(workspace: workspace, path: "openspec/changes/checkout-flow/review.md", content: "# Review\n\n## Verdict\n\nAPPROVE\n")
        try writeArtifact(workspace: workspace, path: "openspec/changes/checkout-flow/decisions.md", content: "# Decisions\n\n- Use CLI for MVP.\n")

        let report = try core.validateArtifacts(featureSlug: "checkout-flow")

        XCTAssertTrue(report.valid)
        XCTAssertTrue(report.issues.isEmpty)
        XCTAssertTrue(report.artifacts.allSatisfy { $0.state == .ready })
    }

    private func okResult(adapter: AgentAdapter) -> ExecutionAdapterResult {
        ExecutionAdapterResult(
            adapter: adapter,
            status: .ok,
            artifactRefs: [],
            logRef: nil,
            telemetryRefs: [],
            tokenUsage: nil,
            error: nil
        )
    }

    private func temporaryWorkspace() throws -> SDDWorkspaceConfiguration {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-sdd-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return SDDWorkspaceConfiguration(root: url, repoId: "test/repo", workspaceId: "test-workspace", stack: "swift")
    }

    private func writeArtifact(workspace: SDDWorkspaceConfiguration, path: String, content: String) throws {
        try content.write(
            to: workspace.root.appendingPathComponent(path),
            atomically: true,
            encoding: .utf8
        )
    }
}
