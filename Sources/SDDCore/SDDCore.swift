import Foundation
import SDDModels

public enum SDDCoreError: Error, LocalizedError, Equatable {
    case runNotFound(String)
    case invalidFeatureSlug(String)
    case invalidTransition(String)
    case adapterResultFailed(String?)
    case artifactNotFound(String)
    case artifactReadFailed(String)
    case intakeParseFailed(String)
    case unsupportedIntakeType(String)
    case openspecWriteFailed(String)
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
        case .intakeParseFailed(let message):
            return message
        case .unsupportedIntakeType(let intakeType):
            return "Unsupported intake type: \(intakeType)"
        case .openspecWriteFailed(let message):
            return "OpenSpec write failed: \(message)"
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
                "normalize-intake"
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
                "normalize_intake"
            ],
            supportedOutputModes: ["json"],
            supportedInterfaceModes: [.cli],
            compatibility: "mvp-cli"
        )
    }

    public func startRun(featureSlug: String, adapter: AgentAdapter, owner: String) throws -> TransitionResult {
        try validateFeatureSlug(featureSlug)
        try artifactStore.createFeatureArtifacts(featureSlug: featureSlug)

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
