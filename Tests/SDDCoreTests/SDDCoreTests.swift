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
}
