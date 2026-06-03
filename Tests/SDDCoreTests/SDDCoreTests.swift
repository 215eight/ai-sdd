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

        let summary = try core.getRunSummary(runId: result.runId)
        XCTAssertEqual(summary.identityAttribution.actorId, "tester")
        XCTAssertEqual(summary.identityAttribution.actorType, .human)
        XCTAssertEqual(summary.identityAttribution.agentAdapter, .codex)
        XCTAssertEqual(summary.identityAttribution.repoId, "test/repo")
        XCTAssertEqual(summary.identityAttribution.workspaceId, "test-workspace")
        XCTAssertEqual(summary.identityAttribution.machineId, "test-machine")
        XCTAssertEqual(summary.identityAttribution.organizationId, "test-org")
    }

    func testStartRunFromIntakeSeedsOpenSpecProposalAndDecisions() throws {
        let workspace = try temporaryWorkspace()
        let core = SDDCore(workspace: workspace)

        let result = try core.startRun(
            intakeMarkdown: """
            ---
            intake_type: prd
            title: Checkout Flow
            source_id: prd-123
            owner: payments
            ---
            # Overview

            Ship a checkout flow for logged-in customers.
            """,
            adapter: .codex,
            owner: "tester"
        )

        XCTAssertEqual(result.featureSlug, "checkout-flow")
        XCTAssertEqual(result.status, .actionRequired)
        XCTAssertEqual(result.phase, .plan)

        let proposal = try core.getArtifact(featureSlug: "checkout-flow", type: "openspec_proposal")
        XCTAssertTrue(proposal.content.contains("Type: `prd`"))
        XCTAssertTrue(proposal.content.contains("Source ID: prd-123"))
        XCTAssertTrue(proposal.content.contains("Owner: payments"))
        XCTAssertTrue(proposal.content.contains("- `checkout-flow` - Checkout Flow"))
        XCTAssertTrue(proposal.content.contains("Ship a checkout flow for logged-in customers."))

        let decisions = try core.getArtifact(featureSlug: "checkout-flow", type: "openspec_decisions")
        XCTAssertTrue(decisions.content.contains("No closed decisions recorded for this intake."))

        let validation = try core.validateArtifacts(featureSlug: "checkout-flow")
        XCTAssertEqual(validation.artifacts.first(where: { $0.ref.type == "openspec_proposal" })?.state, .ready)
        XCTAssertEqual(validation.artifacts.first(where: { $0.ref.type == "openspec_decisions" })?.state, .ready)
        XCTAssertEqual(validation.artifacts.first(where: { $0.ref.type == "openspec_design" })?.state, .placeholder)
    }

    func testStartRunReturnsBlockedWhenFeatureAlreadyHasActiveLock() throws {
        let workspace = try temporaryWorkspace()
        let core = SDDCore(workspace: workspace)
        let first = try core.startRun(featureSlug: "checkout-flow", adapter: .codex, owner: "tester")

        let second = try core.startRun(featureSlug: "checkout-flow", adapter: .claudeCode, owner: "other")

        XCTAssertEqual(second.runId, first.runId)
        XCTAssertEqual(second.featureSlug, "checkout-flow")
        XCTAssertEqual(second.status, .blocked)
        XCTAssertEqual(second.phase, .plan)
        XCTAssertEqual(second.blockedReason, .lockHeld)
        XCTAssertNil(second.action)
    }

    func testStartRunFromIntakeDoesNotOverwriteLockedOpenSpecArtifacts() throws {
        let workspace = try temporaryWorkspace()
        let core = SDDCore(workspace: workspace)
        let first = try core.startRun(
            intakeMarkdown: """
            ---
            intake_type: prd
            title: Checkout Flow
            source_id: prd-123
            owner: payments
            ---
            Original product intent.
            """,
            adapter: .codex,
            owner: "tester"
        )

        let second = try core.startRun(
            intakeMarkdown: """
            ---
            intake_type: prd
            title: Checkout Flow
            source_id: prd-456
            owner: payments
            ---
            Replacement product intent.
            """,
            adapter: .codex,
            owner: "other"
        )

        XCTAssertEqual(second.runId, first.runId)
        XCTAssertEqual(second.status, .blocked)
        XCTAssertEqual(second.blockedReason, .lockHeld)

        let proposal = try core.getArtifact(featureSlug: "checkout-flow", type: "openspec_proposal")
        XCTAssertTrue(proposal.content.contains("Source ID: prd-123"))
        XCTAssertTrue(proposal.content.contains("Original product intent."))
        XCTAssertFalse(proposal.content.contains("prd-456"))
        XCTAssertFalse(proposal.content.contains("Replacement product intent."))
    }

    func testClearLockRemovesRunLockAndRecordsRecoveryEvent() throws {
        let workspace = try temporaryWorkspace()
        let core = SDDCore(workspace: workspace)
        let started = try core.startRun(featureSlug: "checkout-flow", adapter: .codex, owner: "agent-session")

        let cleared = try core.clearLock(runId: started.runId, clearedBy: "operator")

        XCTAssertNil(cleared.lock)
        XCTAssertEqual(cleared.status, .actionRequired)
        XCTAssertEqual(cleared.currentPhase, .plan)
        XCTAssertEqual(cleared.phaseHistory.last?.note, "lock_cleared:operator")

        let persisted = try core.getRunSummary(runId: started.runId)
        XCTAssertNil(persisted.lock)

        let events = try core.listRunEvents(runId: started.runId)
        XCTAssertEqual(events.last?.eventName, "sdd.lock.cleared")
        XCTAssertEqual(events.last?.properties["cleared_by"], "operator")
    }

    func testStartRunStillBlocksWhenActiveRunHasNoLock() throws {
        let workspace = try temporaryWorkspace()
        let core = SDDCore(workspace: workspace)
        let started = try core.startRun(featureSlug: "checkout-flow", adapter: .codex, owner: "agent-session")
        _ = try core.clearLock(runId: started.runId, clearedBy: "operator")

        let second = try core.startRun(featureSlug: "checkout-flow", adapter: .claudeCode, owner: "other")

        XCTAssertEqual(second.runId, started.runId)
        XCTAssertEqual(second.status, .blocked)
        XCTAssertEqual(second.blockedReason, .lockHeld)
    }

    func testClearLockRejectsRunsWithoutActiveLock() throws {
        let workspace = try temporaryWorkspace()
        let core = SDDCore(workspace: workspace)
        let started = try core.startRun(featureSlug: "checkout-flow", adapter: .codex, owner: "agent-session")
        _ = try core.clearLock(runId: started.runId, clearedBy: "operator")

        XCTAssertThrowsError(
            try core.clearLock(runId: started.runId, clearedBy: "operator")
        ) { error in
            XCTAssertEqual(
                error as? SDDCoreError,
                .invalidTransition("Run \(started.runId) does not have an active lock.")
            )
        }
    }

    func testMarkBlockedStopsRunAndRecordsBlocker() throws {
        let workspace = try temporaryWorkspace()
        let core = SDDCore(workspace: workspace)
        let started = try core.startRun(featureSlug: "checkout-flow", adapter: .codex, owner: "agent-session")

        let blocked = try core.markBlocked(
            runId: started.runId,
            reason: .missingInput,
            message: "Waiting for pricing decision.",
            markedBy: "operator"
        )

        XCTAssertEqual(blocked.status, .blocked)
        XCTAssertEqual(blocked.blockedReason, .missingInput)
        XCTAssertNil(blocked.action)

        let summary = try core.getRunSummary(runId: started.runId)
        XCTAssertEqual(summary.status, .blocked)
        XCTAssertNil(summary.lock)
        XCTAssertEqual(summary.blockers.last?.reason, .missingInput)
        XCTAssertEqual(summary.blockers.last?.message, "Waiting for pricing decision.")
        XCTAssertEqual(summary.phaseHistory.last?.note, "blocked:missing_input:operator")

        let events = try core.listRunEvents(runId: started.runId)
        let blockedEvent = try XCTUnwrap(events.first(where: { $0.eventName == "sdd.run.blocked" }))
        XCTAssertEqual(blockedEvent.properties["reason"], "missing_input")
        XCTAssertEqual(blockedEvent.properties["marked_by"], "operator")
    }

    func testMarkBlockedRejectsCompletedRuns() throws {
        let workspace = try temporaryWorkspace()
        let core = SDDCore(workspace: workspace)
        let started = try core.startRun(featureSlug: "checkout-flow", adapter: .codex, owner: "agent-session")
        try writePlanArtifacts(workspace: workspace)
        _ = try core.submitResult(runId: started.runId, phase: .plan, result: okResult(adapter: .codex))
        _ = try core.approveGate(runId: started.runId, phase: .plan, approvedBy: "operator")
        _ = try core.submitResult(runId: started.runId, phase: .implement, result: okResult(adapter: .codex))
        try writeArtifact(workspace: workspace, path: "openspec/changes/checkout-flow/review.md", content: "# Review\n\n## Verdict\n\nAPPROVE\n")
        _ = try core.submitResult(runId: started.runId, phase: .review, result: okResult(adapter: .codex))

        XCTAssertThrowsError(
            try core.markBlocked(
                runId: started.runId,
                reason: .policyViolation,
                message: "Late blocker.",
                markedBy: "operator"
            )
        ) { error in
            XCTAssertEqual(
                error as? SDDCoreError,
                .invalidTransition("Run \(started.runId) is completed and cannot be marked blocked.")
            )
        }
    }

    func testRetryActionReopensBlockedRunWithFreshLock() throws {
        let workspace = try temporaryWorkspace()
        let core = SDDCore(workspace: workspace)
        let started = try core.startRun(featureSlug: "checkout-flow", adapter: .codex, owner: "agent-session")
        _ = try core.markBlocked(
            runId: started.runId,
            reason: .missingInput,
            message: "Waiting for pricing decision.",
            markedBy: "operator"
        )

        let retried = try core.retryAction(runId: started.runId, owner: "retry-agent")

        XCTAssertEqual(retried.status, .actionRequired)
        XCTAssertEqual(retried.phase, .plan)
        XCTAssertEqual(retried.action?.kind, .produceArtifact)

        let summary = try core.getRunSummary(runId: started.runId)
        XCTAssertEqual(summary.status, .actionRequired)
        XCTAssertEqual(summary.lock?.owner, "retry-agent")
        XCTAssertEqual(summary.blockers.last?.reason, .missingInput)
        XCTAssertEqual(summary.phaseHistory.last?.note, "retry_action:retry-agent")

        let events = try core.listRunEvents(runId: started.runId)
        let retryEvent = try XCTUnwrap(events.first(where: { $0.eventName == "sdd.action.retried" }))
        XCTAssertEqual(retryEvent.properties["owner"], "retry-agent")
    }

    func testRetryActionReopensFailedRun() throws {
        let workspace = try temporaryWorkspace()
        let core = SDDCore(workspace: workspace)
        let started = try core.startRun(featureSlug: "checkout-flow", adapter: .codex, owner: "agent-session")

        XCTAssertThrowsError(
            try core.submitResult(
                runId: started.runId,
                phase: .plan,
                result: ExecutionAdapterResult(
                    adapter: .codex,
                    status: .failed,
                    artifactRefs: [],
                    logRef: nil,
                    telemetryRefs: [],
                    tokenUsage: nil,
                    error: "adapter crashed"
                )
            )
        )

        let retried = try core.retryAction(runId: started.runId, owner: "retry-agent")

        XCTAssertEqual(retried.status, .actionRequired)
        XCTAssertEqual(retried.phase, .plan)
        XCTAssertEqual(retried.action?.kind, .produceArtifact)

        let summary = try core.getRunSummary(runId: started.runId)
        XCTAssertEqual(summary.status, .actionRequired)
        XCTAssertEqual(summary.lock?.owner, "retry-agent")
        XCTAssertTrue(summary.phaseHistory.contains { $0.status == .failed && $0.note == "adapter crashed" })
    }

    func testRetryActionRejectsActionRequiredRuns() throws {
        let workspace = try temporaryWorkspace()
        let core = SDDCore(workspace: workspace)
        let started = try core.startRun(featureSlug: "checkout-flow", adapter: .codex, owner: "agent-session")

        XCTAssertThrowsError(
            try core.retryAction(runId: started.runId, owner: "retry-agent")
        ) { error in
            XCTAssertEqual(
                error as? SDDCoreError,
                .invalidTransition("Run \(started.runId) is action_required and cannot be retried.")
            )
        }
    }

    func testSubmitPlanRequiresApprovalAndApproveMovesToImplement() throws {
        let workspace = try temporaryWorkspace()
        let core = SDDCore(workspace: workspace)
        let started = try core.startRun(featureSlug: "checkout-flow", adapter: .codex, owner: "tester")
        try writePlanArtifacts(workspace: workspace)

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

    func testRejectGateBlocksApprovalRequiredRun() throws {
        let workspace = try temporaryWorkspace()
        let core = SDDCore(workspace: workspace)
        let started = try core.startRun(featureSlug: "checkout-flow", adapter: .codex, owner: "tester")
        try writePlanArtifacts(workspace: workspace)
        _ = try core.submitResult(runId: started.runId, phase: .plan, result: okResult(adapter: .codex))

        let rejected = try core.rejectGate(
            runId: started.runId,
            phase: .plan,
            rejectedBy: "reviewer",
            reason: "Design does not cover rollback."
        )

        XCTAssertEqual(rejected.status, .blocked)
        XCTAssertEqual(rejected.phase, .plan)
        XCTAssertEqual(rejected.blockedReason, .approvalRequired)
        XCTAssertNil(rejected.action)

        let summary = try core.getRunSummary(runId: started.runId)
        XCTAssertEqual(summary.status, .blocked)
        XCTAssertNil(summary.lock)
        XCTAssertEqual(summary.blockers.last?.reason, .approvalRequired)
        XCTAssertEqual(summary.blockers.last?.message, "Approval rejected: Design does not cover rollback.")
        XCTAssertEqual(summary.phaseHistory.last?.note, "gate_rejected:plan:reviewer")

        let events = try core.listRunEvents(runId: started.runId)
        let rejectedEvent = try XCTUnwrap(events.first(where: { $0.eventName == "sdd.gate.rejected" }))
        XCTAssertEqual(rejectedEvent.properties["phase"], "plan")
        XCTAssertEqual(rejectedEvent.properties["rejected_by"], "reviewer")
        XCTAssertEqual(rejectedEvent.properties["reason"], "Design does not cover rollback.")
    }

    func testRejectGateRequiresApprovalRequiredRun() throws {
        let workspace = try temporaryWorkspace()
        let core = SDDCore(workspace: workspace)
        let started = try core.startRun(featureSlug: "checkout-flow", adapter: .codex, owner: "tester")

        XCTAssertThrowsError(
            try core.rejectGate(
                runId: started.runId,
                phase: .plan,
                rejectedBy: "reviewer",
                reason: "No approval requested."
            )
        ) { error in
            XCTAssertEqual(
                error as? SDDCoreError,
                .invalidTransition("Run \(started.runId) is not waiting for approval.")
            )
        }
    }

    func testSubmitPlanRejectsPlaceholderDesignAndTasksWithoutAdvancing() throws {
        let workspace = try temporaryWorkspace()
        let core = SDDCore(workspace: workspace)
        let started = try core.startRun(featureSlug: "checkout-flow", adapter: .codex, owner: "tester")

        XCTAssertThrowsError(
            try core.submitResult(runId: started.runId, phase: .plan, result: okResult(adapter: .codex))
        ) { error in
            guard let coreError = error as? SDDCoreError else {
                return XCTFail("Expected SDDCoreError.")
            }
            XCTAssertEqual(
                coreError,
                .artifactValidationFailed("Required artifacts are not ready for checkout-flow: openspec_design=placeholder, openspec_tasks=placeholder")
            )
        }

        let summary = try core.status(runId: started.runId)
        XCTAssertEqual(summary.status, .actionRequired)
        XCTAssertEqual(summary.currentPhase, .plan)
    }

    func testSubmitImplementMovesToReviewAndSubmitReviewCompletes() throws {
        let workspace = try temporaryWorkspace()
        let core = SDDCore(workspace: workspace)
        let started = try core.startRun(featureSlug: "checkout-flow", adapter: .claudeCode, owner: "tester")
        try writePlanArtifacts(workspace: workspace)

        _ = try core.submitResult(runId: started.runId, phase: .plan, result: okResult(adapter: .claudeCode))
        _ = try core.approveGate(runId: started.runId, phase: .plan, approvedBy: "tester")

        let review = try core.submitResult(runId: started.runId, phase: .implement, result: okResult(adapter: .claudeCode))
        XCTAssertEqual(review.status, .actionRequired)
        XCTAssertEqual(review.phase, .review)
        XCTAssertEqual(review.action?.kind, .reviewChanges)

        try writeArtifact(workspace: workspace, path: "openspec/changes/checkout-flow/review.md", content: "# Review\n\n## Verdict\n\nAPPROVE\n")
        let completed = try core.submitResult(runId: started.runId, phase: .review, result: okResult(adapter: .claudeCode))
        XCTAssertEqual(completed.status, .completed)
        XCTAssertNil(completed.action)
    }

    func testCapabilitiesExposeMVPCLIOnly() {
        let core = SDDCore(workspace: SDDWorkspaceConfiguration(root: URL(fileURLWithPath: NSTemporaryDirectory())))

        let capabilities = core.capabilities()

        XCTAssertEqual(capabilities.supportedInterfaceModes, [.cli])
        XCTAssertTrue(capabilities.supportedOperations.contains("get_next_action"))
        XCTAssertTrue(capabilities.supportedOperations.contains("run_loop"))
        XCTAssertTrue(capabilities.supportedCommands.contains("run"))
        XCTAssertTrue(capabilities.supportedCommands.contains("submit-result"))
        XCTAssertTrue(capabilities.supportedOperations.contains("reject_gate"))
        XCTAssertTrue(capabilities.supportedCommands.contains("reject-gate"))
        XCTAssertTrue(capabilities.supportedOperations.contains("validate_artifacts"))
        XCTAssertTrue(capabilities.supportedCommands.contains("validate-artifacts"))
        XCTAssertTrue(capabilities.supportedOperations.contains("normalize_intake"))
        XCTAssertTrue(capabilities.supportedCommands.contains("normalize-intake"))
        XCTAssertTrue(capabilities.supportedOperations.contains("get_run_summary"))
        XCTAssertTrue(capabilities.supportedCommands.contains("get-run-summary"))
        XCTAssertTrue(capabilities.supportedOperations.contains("list_run_events"))
        XCTAssertTrue(capabilities.supportedCommands.contains("list-run-events"))
        XCTAssertTrue(capabilities.supportedOperations.contains("prepare_execution"))
        XCTAssertTrue(capabilities.supportedCommands.contains("prepare-execution"))
        XCTAssertTrue(capabilities.supportedOperations.contains("clear_lock"))
        XCTAssertTrue(capabilities.supportedCommands.contains("clear-lock"))
        XCTAssertTrue(capabilities.supportedOperations.contains("mark_blocked"))
        XCTAssertTrue(capabilities.supportedCommands.contains("mark-blocked"))
        XCTAssertTrue(capabilities.supportedOperations.contains("retry_action"))
        XCTAssertTrue(capabilities.supportedCommands.contains("retry-action"))
        XCTAssertTrue(capabilities.supportedOperations.contains("validate_workspace"))
        XCTAssertTrue(capabilities.supportedCommands.contains("validate-workspace"))
        XCTAssertTrue(capabilities.supportedOperations.contains("validate_secrets"))
        XCTAssertTrue(capabilities.supportedCommands.contains("validate-secrets"))
    }

    func testValidateWorkspacePassesForDefaultTemporaryWorkspace() throws {
        let workspace = try temporaryWorkspace()
        let core = SDDCore(workspace: workspace)

        let report = core.validateWorkspace()

        XCTAssertTrue(report.valid)
        let canonicalRoot = workspace.root.resolvingSymlinksInPath().standardizedFileURL
        XCTAssertEqual(report.root, canonicalRoot.path)
        XCTAssertEqual(report.openspecRoot, canonicalRoot.appendingPathComponent("openspec").path)
        XCTAssertEqual(report.telemetryPath, canonicalRoot.appendingPathComponent(".sdd/telemetry/events.jsonl").path)
        XCTAssertEqual(report.repoId, "test/repo")
        XCTAssertEqual(report.workspaceId, "test-workspace")
        XCTAssertEqual(report.stack, "swift")
        XCTAssertEqual(report.machineId, "test-machine")
        XCTAssertEqual(report.organizationId, "test-org")
        XCTAssertEqual(report.checks.map(\.status), Array(repeating: .passed, count: report.checks.count))
        XCTAssertEqual(report.checks.map(\.name), [
            "workspace_root_exists",
            "workspace_root_is_directory",
            "workspace_root_writable",
            "openspec_root_inside_workspace",
            "telemetry_path_inside_workspace",
            "repo_id_configured",
            "workspace_id_configured",
            "stack_configured",
            "machine_id_configured"
        ])
    }

    func testValidateWorkspaceFailsForMissingRootAndExternalPaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-sdd-tests")
            .appendingPathComponent(UUID().uuidString)
        let workspace = SDDWorkspaceConfiguration(
            root: root,
            openspecRoot: FileManager.default.temporaryDirectory.appendingPathComponent("external-openspec"),
            telemetryPath: FileManager.default.temporaryDirectory.appendingPathComponent("external-events.jsonl"),
            repoId: "",
            workspaceId: "",
            stack: "",
            machineId: ""
        )
        let core = SDDCore(workspace: workspace)

        let report = core.validateWorkspace()

        XCTAssertFalse(report.valid)
        XCTAssertEqual(report.checks.first(where: { $0.name == "workspace_root_exists" })?.status, .failed)
        XCTAssertEqual(report.checks.first(where: { $0.name == "workspace_root_is_directory" })?.status, .failed)
        XCTAssertEqual(report.checks.first(where: { $0.name == "workspace_root_writable" })?.status, .failed)
        XCTAssertEqual(report.checks.first(where: { $0.name == "openspec_root_inside_workspace" })?.status, .failed)
        XCTAssertEqual(report.checks.first(where: { $0.name == "telemetry_path_inside_workspace" })?.status, .failed)
        XCTAssertEqual(report.checks.first(where: { $0.name == "repo_id_configured" })?.status, .failed)
        XCTAssertEqual(report.checks.first(where: { $0.name == "workspace_id_configured" })?.status, .failed)
        XCTAssertEqual(report.checks.first(where: { $0.name == "stack_configured" })?.status, .failed)
        XCTAssertEqual(report.checks.first(where: { $0.name == "machine_id_configured" })?.status, .failed)
    }

    func testWorkspaceConfigurationLoadsLocalConfig() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-sdd-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".sdd"), withIntermediateDirectories: true)
        try """
        {
          "openspec_root": "specs",
          "telemetry_path": ".telemetry/events.jsonl",
          "repo_id": "configured/repo",
          "workspace_id": "configured-workspace",
          "stack": "configured-stack",
          "machine_id": "configured-machine",
          "organization_id": "configured-org"
        }
        """.write(to: root.appendingPathComponent(".sdd/config.json"), atomically: true, encoding: .utf8)

        let workspace = try SDDWorkspaceConfiguration.load(root: root)

        XCTAssertEqual(workspace.openspecRoot.path, root.appendingPathComponent("specs").path)
        XCTAssertEqual(workspace.telemetryPath.path, root.appendingPathComponent(".telemetry/events.jsonl").path)
        XCTAssertEqual(workspace.repoId, "configured/repo")
        XCTAssertEqual(workspace.workspaceId, "configured-workspace")
        XCTAssertEqual(workspace.stack, "configured-stack")
        XCTAssertEqual(workspace.machineId, "configured-machine")
        XCTAssertEqual(workspace.organizationId, "configured-org")

        let identity = workspace.identityAttribution(actorId: "agent-1", actorType: .agent, adapter: .claudeCode)
        XCTAssertEqual(identity.actorId, "agent-1")
        XCTAssertEqual(identity.actorType, .agent)
        XCTAssertEqual(identity.agentAdapter, .claudeCode)
        XCTAssertEqual(identity.repoId, "configured/repo")
        XCTAssertEqual(identity.workspaceId, "configured-workspace")
        XCTAssertEqual(identity.machineId, "configured-machine")
        XCTAssertEqual(identity.organizationId, "configured-org")
    }

    func testSecretValidationUsesConfiguredReferencesWithoutExposingValues() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-sdd-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".sdd"), withIntermediateDirectories: true)
        try """
        {
          "secrets": {
            "telemetry_api_key": "env:SDD_TELEMETRY_API_KEY",
            "warehouse_token": "ci:WAREHOUSE_TOKEN",
            "missing_secret": "env:MISSING_SECRET"
          }
        }
        """.write(to: root.appendingPathComponent(".sdd/config.json"), atomically: true, encoding: .utf8)
        let workspace = try SDDWorkspaceConfiguration.load(root: root)
        let core = SDDCore(
            workspace: workspace,
            secretResolver: RuntimeSecretResolver(
                environment: [
                    "SDD_TELEMETRY_API_KEY": "secret-value",
                    "WAREHOUSE_TOKEN": "ci-secret-value"
                ]
            )
        )

        let report = core.validateSecrets()

        XCTAssertFalse(report.valid)
        XCTAssertEqual(report.checks.map(\.name), ["missing_secret", "telemetry_api_key", "warehouse_token"])
        XCTAssertEqual(report.checks.map(\.configured), [false, true, true])
        XCTAssertFalse(report.checks.map(\.message).joined(separator: " ").contains("secret-value"))
        XCTAssertEqual(try core.resolveSecret(name: "telemetry_api_key"), "secret-value")
        XCTAssertThrowsError(try core.resolveSecret(name: "missing_secret")) { error in
            XCTAssertEqual(error as? SDDCoreError, .secretMissing("Secret missing_secret is not configured."))
        }
    }

    func testTelemetryRedactsSensitivePropertiesBeforePersistenceAndAdapters() throws {
        let workspace = try temporaryWorkspace()
        let metricsRecorder = RecordingMetricsRecorder()
        let traceRecorder = RecordingTraceRecorder()
        let core = SDDCore(
            workspace: workspace,
            metricsRecorder: metricsRecorder,
            traceRecorder: traceRecorder
        )
        let started = try core.startRun(featureSlug: "checkout-flow", adapter: .codex, owner: "tester")
        try writePlanArtifacts(workspace: workspace)

        _ = try core.submitResult(
            runId: started.runId,
            phase: .plan,
            result: ExecutionAdapterResult(
                adapter: .codex,
                status: .ok,
                artifactRefs: [],
                logRef: "https://logs.example/run?sig=signed-secret",
                telemetryRefs: [],
                tokenUsage: TokenAttribution(
                    provider: "openai",
                    model: "gpt-5.5",
                    inputTokens: 1,
                    outputTokens: 2,
                    cachedTokens: nil,
                    reasoningTokens: nil,
                    confidence: .directRequest
                ),
                error: nil
            )
        )

        let event = try XCTUnwrap(try core.listRunEvents(runId: started.runId).first { $0.eventName == "sdd.result.submitted" })
        XCTAssertEqual(event.properties["log_ref"], "[REDACTED]")
        XCTAssertEqual(event.properties["token_model"], "gpt-5.5")

        let span = try XCTUnwrap(traceRecorder.spans.first { $0.name == "sdd.result.submitted" })
        XCTAssertEqual(span.attributes["log_ref"], "[REDACTED]")
        XCTAssertEqual(span.attributes["token_model"], "gpt-5.5")
    }

    func testGetRunSummaryReturnsCompactOpenSpecSummary() throws {
        let workspace = try temporaryWorkspace()
        let core = SDDCore(workspace: workspace)
        let started = try core.startRun(featureSlug: "checkout-flow", adapter: .codex, owner: "tester")

        let summary = try core.getRunSummary(runId: started.runId)

        XCTAssertEqual(summary.runId, started.runId)
        XCTAssertEqual(summary.featureSlug, "checkout-flow")
        XCTAssertEqual(summary.status, .actionRequired)
        XCTAssertEqual(summary.currentPhase, .plan)
    }

    func testListRunEventsReturnsLocalTelemetryForRun() throws {
        let workspace = try temporaryWorkspace()
        let core = SDDCore(workspace: workspace)
        let started = try core.startRun(featureSlug: "checkout-flow", adapter: .codex, owner: "tester")

        var events = try core.listRunEvents(runId: started.runId)
        XCTAssertEqual(events.map(\.eventName), [
            "sdd.run.started",
            "sdd.transition.evaluated"
        ])
        XCTAssertTrue(events.allSatisfy { $0.runId == started.runId })

        try writePlanArtifacts(workspace: workspace)
        _ = try core.submitResult(runId: started.runId, phase: .plan, result: okResult(adapter: .codex))

        events = try core.listRunEvents(runId: started.runId)
        XCTAssertEqual(events.map(\.eventName), [
            "sdd.run.started",
            "sdd.transition.evaluated",
            "sdd.result.submitted",
            "sdd.transition.evaluated"
        ])
        XCTAssertEqual(events.last?.status, .approvalRequired)
    }

    func testTelemetryEventsFlowThroughMetricsAndTraceAdapters() throws {
        let workspace = try temporaryWorkspace()
        let metricsRecorder = RecordingMetricsRecorder()
        let traceRecorder = RecordingTraceRecorder()
        let core = SDDCore(
            workspace: workspace,
            metricsRecorder: metricsRecorder,
            traceRecorder: traceRecorder
        )

        let started = try core.startRun(featureSlug: "checkout-flow", adapter: .codex, owner: "tester")

        XCTAssertEqual(started.status, .actionRequired)
        XCTAssertEqual(metricsRecorder.counters.count, 4)
        XCTAssertEqual(metricsRecorder.counters.map(\.name), [
            "sdd.events.emitted",
            "sdd.workflow.status.action_required",
            "sdd.events.emitted",
            "sdd.workflow.status.action_required"
        ])
        XCTAssertEqual(metricsRecorder.counters.first?.attributes["event_name"], "sdd.run.started")
        XCTAssertEqual(metricsRecorder.counters.first?.attributes["feature_slug"], "checkout-flow")
        XCTAssertEqual(metricsRecorder.counters.first?.attributes["adapter"], "codex")
        XCTAssertEqual(metricsRecorder.counters.first?.attributes["repo_id"], "test/repo")
        XCTAssertEqual(metricsRecorder.counters.first?.attributes["workspace_id"], "test-workspace")
        XCTAssertEqual(metricsRecorder.counters.first?.attributes["stack"], "swift")
        XCTAssertEqual(metricsRecorder.counters.first?.attributes["actor_id"], "tester")
        XCTAssertEqual(metricsRecorder.counters.first?.attributes["actor_type"], "human")
        XCTAssertEqual(metricsRecorder.counters.first?.attributes["machine_id"], "test-machine")
        XCTAssertEqual(metricsRecorder.counters.first?.attributes["organization_id"], "test-org")

        XCTAssertEqual(traceRecorder.spans.map(\.name), [
            "sdd.run.started",
            "sdd.transition.evaluated"
        ])
        XCTAssertEqual(traceRecorder.spans.first?.runId, started.runId)
        XCTAssertEqual(traceRecorder.spans.first?.featureSlug, "checkout-flow")
        XCTAssertEqual(traceRecorder.spans.first?.phase, .plan)
        XCTAssertEqual(traceRecorder.spans.first?.status, .actionRequired)
        XCTAssertEqual(traceRecorder.spans.first?.attributes["interface"], "cli")
        XCTAssertEqual(traceRecorder.spans.first?.attributes["actor_id"], "tester")
    }

    func testSubmitResultPersistsAndEmitsTokenAttribution() throws {
        let workspace = try temporaryWorkspace()
        let core = SDDCore(workspace: workspace)
        let started = try core.startRun(featureSlug: "checkout-flow", adapter: .claudeCode, owner: "tester")
        try writePlanArtifacts(workspace: workspace)

        let tokenUsage = TokenAttribution(
            provider: "anthropic",
            model: "claude-sonnet-4",
            inputTokens: 12_345,
            outputTokens: 678,
            cachedTokens: 90,
            reasoningTokens: nil,
            confidence: .sessionScoped
        )
        _ = try core.submitResult(
            runId: started.runId,
            phase: .plan,
            result: ExecutionAdapterResult(
                adapter: .claudeCode,
                status: .ok,
                artifactRefs: [],
                logRef: "logs/\(started.runId).log",
                telemetryRefs: [
                    TelemetryRef(eventId: "evt_adapter", traceId: "trace_adapter")
                ],
                tokenUsage: tokenUsage,
                error: nil
            )
        )

        let summary = try core.getRunSummary(runId: started.runId)
        XCTAssertEqual(summary.tokenUsageSummary, [tokenUsage])
        XCTAssertEqual(summary.telemetryRefs, [
            TelemetryRef(eventId: "evt_adapter", traceId: "trace_adapter")
        ])

        let events = try core.listRunEvents(runId: started.runId)
        let submitted = try XCTUnwrap(events.first(where: { $0.eventName == "sdd.result.submitted" }))
        XCTAssertEqual(submitted.properties["phase"], "plan")
        XCTAssertEqual(submitted.properties["result_adapter"], "claude-code")
        XCTAssertEqual(submitted.properties["log_ref"], "logs/\(started.runId).log")
        XCTAssertEqual(submitted.properties["telemetry_ref_count"], "1")
        XCTAssertEqual(submitted.properties["token_provider"], "anthropic")
        XCTAssertEqual(submitted.properties["token_model"], "claude-sonnet-4")
        XCTAssertEqual(submitted.properties["input_tokens"], "12345")
        XCTAssertEqual(submitted.properties["output_tokens"], "678")
        XCTAssertEqual(submitted.properties["cached_tokens"], "90")
        XCTAssertNil(submitted.properties["reasoning_tokens"])
        XCTAssertEqual(submitted.properties["token_confidence"], "session_scoped")
    }

    func testPrepareExecutionUsesActiveAdapterAndNextAction() throws {
        let workspace = try temporaryWorkspace()
        let core = SDDCore(workspace: workspace)
        let started = try core.startRun(featureSlug: "checkout-flow", adapter: .codex, owner: "tester")

        let invocation = try core.prepareExecution(runId: started.runId)

        XCTAssertEqual(invocation.adapter, .codex)
        XCTAssertEqual(invocation.runId, started.runId)
        XCTAssertEqual(invocation.featureSlug, "checkout-flow")
        XCTAssertEqual(invocation.phase, .plan)
        XCTAssertEqual(invocation.agentRole, "sdd-planner")
        XCTAssertEqual(invocation.requiredInputs.map(\.type), ["openspec_proposal", "openspec_decisions"])
        XCTAssertEqual(invocation.requiredOutputs.map(\.type), ["openspec_design", "openspec_tasks"])
        XCTAssertEqual(invocation.completionContract.submitPhase, .plan)
        XCTAssertTrue(invocation.prompt.contains("Adapter: codex"))
        XCTAssertTrue(invocation.prompt.contains("Produce a decision-closed implementation plan"))
        XCTAssertEqual(invocation.submitCommand, "sdd submit-result --run-id \(started.runId) --phase plan --json < result.json")
    }

    func testRunLoopStartsRunAndReturnsExecutableInvocationBoundary() throws {
        let workspace = try temporaryWorkspace()
        let core = SDDCore(workspace: workspace)

        let loop = try core.runLoop(
            featureSlug: "checkout-flow",
            adapter: .claudeCode,
            owner: "agent-session",
            actorType: .agent
        )

        XCTAssertEqual(loop.status, .actionRequired)
        XCTAssertEqual(loop.phase, .plan)
        XCTAssertEqual(loop.iterations, 1)
        XCTAssertEqual(loop.nextAction.action?.kind, .produceArtifact)
        XCTAssertEqual(loop.invocation?.adapter, .claudeCode)
        XCTAssertEqual(loop.invocation?.runId, loop.runId)
        XCTAssertTrue(loop.message.contains("Executable action is ready"))

        let summary = try core.getRunSummary(runId: loop.runId)
        XCTAssertEqual(summary.identityAttribution.actorType, .agent)
        XCTAssertEqual(summary.identityAttribution.agentAdapter, .claudeCode)
    }

    func testRunLoopStopsAtApprovalBoundaryWithoutInvocation() throws {
        let workspace = try temporaryWorkspace()
        let core = SDDCore(workspace: workspace)
        let started = try core.startRun(featureSlug: "checkout-flow", adapter: .codex, owner: "tester")
        try writePlanArtifacts(workspace: workspace)
        _ = try core.submitResult(runId: started.runId, phase: .plan, result: okResult(adapter: .codex))

        let loop = try core.runLoop(runId: started.runId, owner: "agent-session")

        XCTAssertEqual(loop.status, .approvalRequired)
        XCTAssertEqual(loop.phase, .plan)
        XCTAssertNil(loop.invocation)
        XCTAssertTrue(loop.message.contains("Human approval is required"))
    }

    func testPrepareExecutionCanOverrideAdapter() throws {
        let workspace = try temporaryWorkspace()
        let core = SDDCore(workspace: workspace)
        let started = try core.startRun(featureSlug: "checkout-flow", adapter: .codex, owner: "tester")

        let invocation = try core.prepareExecution(runId: started.runId, adapter: .claudeCode)

        XCTAssertEqual(invocation.adapter, .claudeCode)
        XCTAssertTrue(invocation.prompt.contains("Adapter: claude-code"))
    }

    func testPrepareExecutionRejectsApprovalRequiredRun() throws {
        let workspace = try temporaryWorkspace()
        let core = SDDCore(workspace: workspace)
        let started = try core.startRun(featureSlug: "checkout-flow", adapter: .codex, owner: "tester")
        try writePlanArtifacts(workspace: workspace)
        _ = try core.submitResult(runId: started.runId, phase: .plan, result: okResult(adapter: .codex))

        XCTAssertThrowsError(
            try core.prepareExecution(runId: started.runId)
        ) { error in
            XCTAssertEqual(
                error as? SDDCoreError,
                .invalidTransition("Run \(started.runId) is approval_required, not action_required.")
            )
        }
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
        return SDDWorkspaceConfiguration(
            root: url,
            repoId: "test/repo",
            workspaceId: "test-workspace",
            stack: "swift",
            machineId: "test-machine",
            organizationId: "test-org"
        )
    }

    private func writeArtifact(workspace: SDDWorkspaceConfiguration, path: String, content: String) throws {
        try content.write(
            to: workspace.root.appendingPathComponent(path),
            atomically: true,
            encoding: .utf8
        )
    }

    private func writePlanArtifacts(workspace: SDDWorkspaceConfiguration) throws {
        try writeArtifact(
            workspace: workspace,
            path: "openspec/changes/checkout-flow/design.md",
            content: "# Design\n\nUse the payment service boundary.\n"
        )
        try writeArtifact(
            workspace: workspace,
            path: "openspec/changes/checkout-flow/tasks.md",
            content: "# Tasks\n\n- [x] Define payment adapter.\n"
        )
    }
}

private final class RecordingMetricsRecorder: SDDMetricsRecorder {
    struct Counter: Equatable {
        var name: String
        var value: Int
        var attributes: [String: String]
    }

    private(set) var counters: [Counter] = []

    func incrementCounter(name: String, by value: Int, attributes: [String: String]) {
        counters.append(Counter(name: name, value: value, attributes: attributes))
    }
}

private final class RecordingTraceRecorder: SDDTraceRecorder {
    private(set) var spans: [SDDTraceSpan] = []

    func recordSpan(_ span: SDDTraceSpan) {
        spans.append(span)
    }
}
