import Foundation
import SDDModels

public enum SDDCoreError: Error, LocalizedError, Equatable {
    case runNotFound(String)
    case invalidFeatureSlug(String)
    case invalidTransition(String)
    case adapterResultFailed(String?)
    case artifactNotFound(String)
    case artifactReadFailed(String)
    case artifactValidationFailed(String)
    case intakeParseFailed(String)
    case unsupportedIntakeType(String)
    case openspecWriteFailed(String)
    case telemetryReadFailed(String)
    case telemetryWriteFailed(String)

    public var errorDescription: String? {
        switch self {
        case .runNotFound(let runID):
            return "Run not found: \(runID)"
        case .invalidFeatureSlug(let featureSlug):
            return "Invalid feature slug: \(featureSlug)"
        case .invalidTransition(let message):
            return message
        case .adapterResultFailed(let message):
            return message ?? "Execution adapter failed."
        case .artifactNotFound(let artifact):
            return "Artifact not found: \(artifact)"
        case .artifactReadFailed(let artifact):
            return "Artifact could not be read as UTF-8 text: \(artifact)"
        case .artifactValidationFailed(let message):
            return message
        case .intakeParseFailed(let message):
            return message
        case .unsupportedIntakeType(let intakeType):
            return "Unsupported intake type: \(intakeType)"
        case .openspecWriteFailed(let message):
            return "OpenSpec write failed: \(message)"
        case .telemetryReadFailed(let message):
            return "Telemetry read failed: \(message)"
        case .telemetryWriteFailed(let message):
            return "Telemetry write failed: \(message)"
        }
    }
}

public struct SDDWorkspaceConfiguration: Equatable {
    public var root: URL
    public var openspecRoot: URL
    public var telemetryPath: URL
    public var repoId: String
    public var workspaceId: String
    public var stack: String

    public init(
        root: URL,
        openspecRoot: URL? = nil,
        telemetryPath: URL? = nil,
        repoId: String = "local",
        workspaceId: String = "local",
        stack: String = "swift"
    ) {
        self.root = root
        self.openspecRoot = openspecRoot ?? root.appendingPathComponent("openspec")
        self.telemetryPath = telemetryPath ?? root.appendingPathComponent(".sdd/telemetry/events.jsonl")
        self.repoId = repoId
        self.workspaceId = workspaceId
        self.stack = stack
    }
}

public final class SDDCore {
    private let workspace: SDDWorkspaceConfiguration
    private let artifactStore: OpenSpecArtifactStore
    private let telemetrySink: LocalJSONLTelemetrySink
    private let workflowEngine: WorkflowEngine

    public init(workspace: SDDWorkspaceConfiguration) {
        self.workspace = workspace
        self.artifactStore = OpenSpecArtifactStore(workspace: workspace)
        self.telemetrySink = LocalJSONLTelemetrySink(path: workspace.telemetryPath)
        self.workflowEngine = WorkflowEngine()
    }

    public func capabilities() -> Capabilities {
        Capabilities(
            supportedCommands: [
                "capabilities",
                "start",
                "next",
                "submit-result",
                "answer-prompt",
                "approve-gate",
                "status",
                "list-artifacts",
                "get-artifact",
                "validate-artifacts",
                "normalize-intake",
                "get-run-summary",
                "list-run-events",
                "prepare-execution",
                "clear-lock"
            ],
            supportedOperations: [
                "start_run",
                "get_next_action",
                "submit_result",
                "answer_prompt",
                "approve_gate",
                "get_status",
                "list_artifacts",
                "get_artifact",
                "validate_artifacts",
                "normalize_intake",
                "get_run_summary",
                "list_run_events",
                "prepare_execution",
                "clear_lock"
            ],
            supportedOutputModes: ["json"],
            supportedInterfaceModes: [.cli],
            compatibility: "mvp-cli"
        )
    }

    public func startRun(featureSlug: String, adapter: AgentAdapter, owner: String) throws -> TransitionResult {
        try validateFeatureSlug(featureSlug)
        if let existing = try activeRun(featureSlug: featureSlug) {
            return lockHeldResult(existing)
        }
        try artifactStore.createFeatureArtifacts(featureSlug: featureSlug)
        return try createRun(featureSlug: featureSlug, adapter: adapter, owner: owner)
    }

    public func startRun(intakeMarkdown: String, adapter: AgentAdapter, owner: String) throws -> TransitionResult {
        let intake = try normalizeIntake(markdown: intakeMarkdown)
        guard let featureSlug = intake.sliceReadyRequirements.first?.featureSlug else {
            throw SDDCoreError.intakeParseFailed("Normalized intake must include at least one slice-ready requirement.")
        }
        try validateFeatureSlug(featureSlug)
        if let existing = try activeRun(featureSlug: featureSlug) {
            return lockHeldResult(existing)
        }
        try artifactStore.createFeatureArtifacts(featureSlug: featureSlug, intake: intake)
        return try createRun(featureSlug: featureSlug, adapter: adapter, owner: owner)
    }

    private func createRun(featureSlug: String, adapter: AgentAdapter, owner: String) throws -> TransitionResult {
        let now = Date()
        let runSummary = RunSummary(
            runId: "run_\(UUID().uuidString.lowercased())",
            featureSlug: featureSlug,
            status: .actionRequired,
            currentPhase: .plan,
            activeAdapter: adapter,
            lock: LockInfo(owner: owner, acquiredAt: now, expiresAt: nil),
            phaseHistory: [
                PhaseHistoryEntry(phase: .plan, status: .actionRequired, at: now, note: "run_started")
            ],
            approvals: [],
            blockers: [],
            telemetryRefs: [],
            tokenUsageSummary: []
        )

        try artifactStore.writeRunSummary(runSummary)
        try emit(eventName: "sdd.run.started", summary: runSummary, properties: [:])
        return try nextAction(runId: runSummary.runId)
    }

    public func nextAction(runId: String) throws -> TransitionResult {
        let summary = try artifactStore.findRunSummary(runId: runId)
        let input = TransitionInput(
            runSummary: summary,
            artifactRefs: artifactStore.artifactRefs(featureSlug: summary.featureSlug),
            latestSubmittedResult: nil,
            workspaceContext: WorkspaceContext(repo: workspace.repoId, stack: workspace.stack)
        )
        let result = workflowEngine.evaluate(input)
        try emit(eventName: "sdd.transition.evaluated", summary: summary, properties: ["status": result.status.rawValue])
        return result
    }

    public func submitResult(runId: String, phase: WorkflowPhase, result: ExecutionAdapterResult) throws -> TransitionResult {
        var summary = try artifactStore.findRunSummary(runId: runId)
        guard summary.currentPhase == phase else {
            throw SDDCoreError.invalidTransition("Cannot submit phase \(phase.rawValue) while current phase is \(summary.currentPhase.rawValue).")
        }
        guard result.status == .ok else {
            summary.status = .failed
            summary.phaseHistory.append(PhaseHistoryEntry(phase: phase, status: .failed, at: Date(), note: result.error))
            try artifactStore.writeRunSummary(summary)
            throw SDDCoreError.adapterResultFailed(result.error)
        }

        let validation = artifactStore.validateArtifacts(
            featureSlug: summary.featureSlug,
            requiredTypes: requiredArtifactTypes(for: phase)
        )
        guard validation.valid else {
            throw SDDCoreError.artifactValidationFailed(validationMessage(for: validation))
        }

        if let tokenUsage = result.tokenUsage {
            summary.tokenUsageSummary.append(tokenUsage)
        }
        summary.telemetryRefs.append(contentsOf: result.telemetryRefs)

        switch phase {
        case .plan:
            summary.status = .approvalRequired
            summary.phaseHistory.append(PhaseHistoryEntry(phase: .plan, status: .approvalRequired, at: Date(), note: "plan_submitted"))
        case .implement:
            summary.currentPhase = .review
            summary.status = .actionRequired
            summary.phaseHistory.append(PhaseHistoryEntry(phase: .implement, status: .actionRequired, at: Date(), note: "implementation_submitted"))
        case .review:
            summary.status = .completed
            summary.phaseHistory.append(PhaseHistoryEntry(phase: .review, status: .completed, at: Date(), note: "review_submitted"))
        }

        try artifactStore.writeRunSummary(summary)
        try emit(eventName: "sdd.result.submitted", summary: summary, properties: ["phase": phase.rawValue])
        return try nextAction(runId: runId)
    }

    public func answerPrompt(runId: String, promptId: String, answer: String) throws -> TransitionResult {
        var summary = try artifactStore.findRunSummary(runId: runId)
        summary.status = .actionRequired
        summary.phaseHistory.append(
            PhaseHistoryEntry(
                phase: summary.currentPhase,
                status: .actionRequired,
                at: Date(),
                note: "prompt_answered:\(promptId):\(answer)"
            )
        )
        try artifactStore.writeRunSummary(summary)
        try emit(eventName: "sdd.prompt.answered", summary: summary, properties: ["prompt_id": promptId])
        return try nextAction(runId: runId)
    }

    public func approveGate(runId: String, phase: WorkflowPhase, approvedBy: String) throws -> TransitionResult {
        var summary = try artifactStore.findRunSummary(runId: runId)
        guard summary.status == .approvalRequired else {
            throw SDDCoreError.invalidTransition("Run \(runId) is not waiting for approval.")
        }
        guard summary.currentPhase == phase else {
            throw SDDCoreError.invalidTransition("Cannot approve phase \(phase.rawValue) while current phase is \(summary.currentPhase.rawValue).")
        }

        summary.approvals.append(
            ApprovalRecord(
                gateId: "\(phase.rawValue)_approval",
                phase: phase,
                approvedBy: approvedBy,
                approvedAt: Date()
            )
        )

        switch phase {
        case .plan:
            summary.currentPhase = .implement
            summary.status = .actionRequired
            summary.phaseHistory.append(PhaseHistoryEntry(phase: .implement, status: .actionRequired, at: Date(), note: "plan_approved"))
        case .implement:
            throw SDDCoreError.invalidTransition("The MVP workflow has no implementation approval gate.")
        case .review:
            summary.status = .completed
            summary.phaseHistory.append(PhaseHistoryEntry(phase: .review, status: .completed, at: Date(), note: "review_approved"))
        }

        try artifactStore.writeRunSummary(summary)
        try emit(eventName: "sdd.gate.approved", summary: summary, properties: ["phase": phase.rawValue])
        return try nextAction(runId: runId)
    }

    public func status(runId: String) throws -> RunSummary {
        try artifactStore.findRunSummary(runId: runId)
    }

    public func getRunSummary(runId: String) throws -> RunSummary {
        try status(runId: runId)
    }

    public func listRunEvents(runId: String) throws -> [TelemetryEvent] {
        _ = try artifactStore.findRunSummary(runId: runId)
        return try telemetrySink.listEvents(runId: runId)
    }

    public func prepareExecution(runId: String, adapter: AgentAdapter? = nil) throws -> ExecutionAdapterInvocation {
        let summary = try artifactStore.findRunSummary(runId: runId)
        let action = try nextAction(runId: runId)
        guard action.status == .actionRequired else {
            throw SDDCoreError.invalidTransition("Run \(runId) is \(action.status.rawValue), not action_required.")
        }
        guard let workflowAction = action.action,
              let completionContract = action.completionContract,
              let agentRole = action.agentRole else {
            throw SDDCoreError.invalidTransition("Run \(runId) does not have an executable action.")
        }

        let selectedAdapter = adapter ?? summary.activeAdapter
        return ExecutionAdapterRenderer(adapter: selectedAdapter).render(
            runId: action.runId,
            featureSlug: action.featureSlug,
            phase: action.phase,
            agentRole: agentRole,
            action: workflowAction,
            completionContract: completionContract
        )
    }

    public func clearLock(runId: String, clearedBy: String) throws -> RunSummary {
        var summary = try artifactStore.findRunSummary(runId: runId)
        guard summary.lock != nil else {
            throw SDDCoreError.invalidTransition("Run \(runId) does not have an active lock.")
        }

        summary.lock = nil
        summary.phaseHistory.append(
            PhaseHistoryEntry(
                phase: summary.currentPhase,
                status: summary.status,
                at: Date(),
                note: "lock_cleared:\(clearedBy)"
            )
        )

        try artifactStore.writeRunSummary(summary)
        try emit(eventName: "sdd.lock.cleared", summary: summary, properties: ["cleared_by": clearedBy])
        return summary
    }

    public func listArtifacts(featureSlug: String) throws -> [ArtifactDescriptor] {
        try validateFeatureSlug(featureSlug)
        return artifactStore.artifactDescriptors(featureSlug: featureSlug)
    }

    public func getArtifact(featureSlug: String, type: String) throws -> ArtifactContent {
        try validateFeatureSlug(featureSlug)
        return try artifactStore.readArtifact(featureSlug: featureSlug, type: type)
    }

    public func validateArtifacts(featureSlug: String) throws -> ArtifactValidationReport {
        try validateFeatureSlug(featureSlug)
        return artifactStore.validateArtifacts(featureSlug: featureSlug)
    }

    public func normalizeIntake(markdown: String) throws -> NormalizedIntake {
        try IntakeNormalizer(workspace: workspace).normalize(markdown: markdown)
    }

    private func validateFeatureSlug(_ featureSlug: String) throws {
        let pattern = #"^[a-z0-9]+(-[a-z0-9]+)*$"#
        if featureSlug.range(of: pattern, options: .regularExpression) == nil {
            throw SDDCoreError.invalidFeatureSlug(featureSlug)
        }
    }

    private func activeRun(featureSlug: String) throws -> RunSummary? {
        guard let summary = try artifactStore.runSummary(featureSlug: featureSlug),
              !isTerminal(summary.status) else {
            return nil
        }

        return summary
    }

    private func isTerminal(_ status: WorkflowStatus) -> Bool {
        status == .completed || status == .failed
    }

    private func lockHeldResult(_ summary: RunSummary) -> TransitionResult {
        TransitionResult(
            runId: summary.runId,
            featureSlug: summary.featureSlug,
            status: .blocked,
            phase: summary.currentPhase,
            agentRole: nil,
            action: nil,
            completionContract: nil,
            blockedReason: .lockHeld,
            failedReason: nil
        )
    }

    private func requiredArtifactTypes(for phase: WorkflowPhase) -> [String] {
        switch phase {
        case .plan:
            return ["openspec_design", "openspec_tasks"]
        case .implement:
            return []
        case .review:
            return ["openspec_review"]
        }
    }

    private func validationMessage(for report: ArtifactValidationReport) -> String {
        let issueSummary = report.issues
            .map { "\($0.ref.type)=\($0.reason.rawValue)" }
            .joined(separator: ", ")
        return "Required artifacts are not ready for \(report.featureSlug): \(issueSummary)"
    }

    private func emit(eventName: String, summary: RunSummary, properties: [String: String]) throws {
        let event = TelemetryEvent(
            eventId: "evt_\(UUID().uuidString.lowercased())",
            eventName: eventName,
            runId: summary.runId,
            featureSlug: summary.featureSlug,
            phase: summary.currentPhase,
            status: summary.status,
            adapter: summary.activeAdapter,
            interface: .cli,
            timestamp: Date(),
            properties: properties
        )
        try telemetrySink.emit(event)
    }
}
