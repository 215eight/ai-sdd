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
    case configurationReadFailed(String)
    case secretReferenceInvalid(String)
    case secretMissing(String)

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
        case .configurationReadFailed(let message):
            return "Configuration read failed: \(message)"
        case .secretReferenceInvalid(let message):
            return "Secret reference is invalid: \(message)"
        case .secretMissing(let message):
            return message
        }
    }
}

public struct SDDWorkspaceConfigDocument: Codable, Equatable {
    public var openspecRoot: String?
    public var telemetryPath: String?
    public var repoId: String?
    public var workspaceId: String?
    public var stack: String?
    public var machineId: String?
    public var organizationId: String?
    public var secrets: [String: String]?

    public init(
        openspecRoot: String? = nil,
        telemetryPath: String? = nil,
        repoId: String? = nil,
        workspaceId: String? = nil,
        stack: String? = nil,
        machineId: String? = nil,
        organizationId: String? = nil,
        secrets: [String: String]? = nil
    ) {
        self.openspecRoot = openspecRoot
        self.telemetryPath = telemetryPath
        self.repoId = repoId
        self.workspaceId = workspaceId
        self.stack = stack
        self.machineId = machineId
        self.organizationId = organizationId
        self.secrets = secrets
    }
}

public struct SDDWorkspaceConfiguration: Equatable {
    public var root: URL
    public var openspecRoot: URL
    public var telemetryPath: URL
    public var repoId: String
    public var workspaceId: String
    public var stack: String
    public var machineId: String
    public var organizationId: String?
    public var secretReferences: [SecretReference]

    public init(
        root: URL,
        openspecRoot: URL? = nil,
        telemetryPath: URL? = nil,
        repoId: String = "local",
        workspaceId: String = "local",
        stack: String = "swift",
        machineId: String = SDDWorkspaceConfiguration.defaultMachineId(),
        organizationId: String? = nil,
        secretReferences: [SecretReference] = []
    ) {
        self.root = root
        self.openspecRoot = openspecRoot ?? root.appendingPathComponent("openspec")
        self.telemetryPath = telemetryPath ?? root.appendingPathComponent(".sdd/telemetry/events.jsonl")
        self.repoId = repoId
        self.workspaceId = workspaceId
        self.stack = stack
        self.machineId = machineId
        self.organizationId = organizationId
        self.secretReferences = secretReferences
    }

    public static func load(root: URL) throws -> SDDWorkspaceConfiguration {
        let configURL = root.appendingPathComponent(".sdd/config.json")
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return SDDWorkspaceConfiguration(root: root)
        }

        do {
            let document = try SDDJSON.decoder().decode(
                SDDWorkspaceConfigDocument.self,
                from: Data(contentsOf: configURL)
            )
            return SDDWorkspaceConfiguration(
                root: root,
                openspecRoot: document.openspecRoot.map { resolveConfiguredPath($0, root: root) },
                telemetryPath: document.telemetryPath.map { resolveConfiguredPath($0, root: root) },
                repoId: nonEmpty(document.repoId) ?? "local",
                workspaceId: nonEmpty(document.workspaceId) ?? "local",
                stack: nonEmpty(document.stack) ?? "swift",
                machineId: nonEmpty(document.machineId) ?? defaultMachineId(),
                organizationId: nonEmpty(document.organizationId),
                secretReferences: try parseSecretReferences(document.secrets ?? [:])
            )
        } catch {
            throw SDDCoreError.configurationReadFailed(error.localizedDescription)
        }
    }

    public func identityAttribution(actorId: String, actorType: ActorType, adapter: AgentAdapter?) -> IdentityAttribution {
        IdentityAttribution(
            actorId: actorId,
            actorType: actorType,
            agentAdapter: adapter,
            repoId: repoId,
            workspaceId: workspaceId,
            machineId: machineId,
            organizationId: organizationId
        )
    }

    private static func parseSecretReferences(_ raw: [String: String]) throws -> [SecretReference] {
        try raw
            .sorted { $0.key < $1.key }
            .map { name, reference in
                let pieces = reference.split(separator: ":", maxSplits: 1).map(String.init)
                guard pieces.count == 2,
                      let source = SecretSource(rawValue: pieces[0]),
                      let key = nonEmpty(pieces[1]) else {
                    throw SDDCoreError.secretReferenceInvalid("\(name)=\(reference)")
                }
                return SecretReference(name: name, source: source, key: key)
            }
    }

    private static func resolveConfiguredPath(_ value: String, root: URL) -> URL {
        if value.hasPrefix("/") {
            return URL(fileURLWithPath: value)
        }
        return root.appendingPathComponent(value)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    public static func defaultMachineId() -> String {
        Host.current().localizedName ?? "local-machine"
    }
}

public final class SDDCore {
    private let workspace: SDDWorkspaceConfiguration
    private let artifactStore: OpenSpecArtifactStore
    private let telemetrySink: LocalJSONLTelemetrySink
    private let metricsRecorder: any SDDMetricsRecorder
    private let traceRecorder: any SDDTraceRecorder
    private let secretResolver: any SecretResolving
    private let workflowEngine: WorkflowEngine

    public init(
        workspace: SDDWorkspaceConfiguration,
        metricsRecorder: any SDDMetricsRecorder = NoopSDDMetricsRecorder(),
        traceRecorder: any SDDTraceRecorder = NoopSDDTraceRecorder(),
        secretResolver: any SecretResolving = RuntimeSecretResolver()
    ) {
        self.workspace = workspace
        self.artifactStore = OpenSpecArtifactStore(workspace: workspace)
        self.telemetrySink = LocalJSONLTelemetrySink(path: workspace.telemetryPath)
        self.metricsRecorder = metricsRecorder
        self.traceRecorder = traceRecorder
        self.secretResolver = secretResolver
        self.workflowEngine = WorkflowEngine()
    }

    public func capabilities() -> Capabilities {
        Capabilities(
            supportedCommands: [
                "capabilities",
                "start",
                "run",
                "next",
                "submit-result",
                "answer-prompt",
                "approve-gate",
                "reject-gate",
                "status",
                "list-artifacts",
                "get-artifact",
                "validate-artifacts",
                "normalize-intake",
                "get-run-summary",
                "list-run-events",
                "prepare-execution",
                "clear-lock",
                "mark-blocked",
                "retry-action",
                "validate-workspace",
                "validate-secrets"
            ],
            supportedOperations: [
                "start_run",
                "run_loop",
                "get_next_action",
                "submit_result",
                "answer_prompt",
                "approve_gate",
                "reject_gate",
                "get_status",
                "list_artifacts",
                "get_artifact",
                "validate_artifacts",
                "normalize_intake",
                "get_run_summary",
                "list_run_events",
                "prepare_execution",
                "clear_lock",
                "mark_blocked",
                "retry_action",
                "validate_workspace",
                "validate_secrets"
            ],
            supportedOutputModes: ["json"],
            supportedInterfaceModes: [.cli],
            compatibility: "mvp-cli"
        )
    }

    public func validateWorkspace() -> WorkspaceValidationReport {
        let root = canonicalURL(workspace.root)
        let openspecRoot = canonicalURL(workspace.openspecRoot)
        let telemetryPath = canonicalURL(workspace.telemetryPath)
        var checks: [WorkspaceValidationCheck] = []

        var isDirectory: ObjCBool = false
        let rootExists = FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory)
        let rootIsDirectory = rootExists && isDirectory.boolValue
        let rootIsWritable = rootIsDirectory && FileManager.default.isWritableFile(atPath: root.path)
        let openspecInsideWorkspace = isPath(openspecRoot, inside: root)
        let telemetryInsideWorkspace = isPath(telemetryPath, inside: root)
        let repoIDConfigured = !workspace.repoId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let workspaceIDConfigured = !workspace.workspaceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let stackConfigured = !workspace.stack.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let machineIDConfigured = !workspace.machineId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        checks.append(
            WorkspaceValidationCheck(
                name: "workspace_root_exists",
                status: rootExists ? .passed : .failed,
                path: root.path,
                message: rootExists ? "Workspace root exists." : "Workspace root does not exist."
            )
        )
        checks.append(
            WorkspaceValidationCheck(
                name: "workspace_root_is_directory",
                status: rootIsDirectory ? .passed : .failed,
                path: root.path,
                message: rootIsDirectory ? "Workspace root is a directory." : "Workspace root is not a directory."
            )
        )
        checks.append(
            WorkspaceValidationCheck(
                name: "workspace_root_writable",
                status: rootIsWritable ? .passed : .failed,
                path: root.path,
                message: rootIsWritable ? "Workspace root is writable." : "Workspace root is not writable."
            )
        )
        checks.append(
            WorkspaceValidationCheck(
                name: "openspec_root_inside_workspace",
                status: openspecInsideWorkspace ? .passed : .failed,
                path: openspecRoot.path,
                message: openspecInsideWorkspace ? "OpenSpec root is inside the workspace." : "OpenSpec root must be inside the workspace."
            )
        )
        checks.append(
            WorkspaceValidationCheck(
                name: "telemetry_path_inside_workspace",
                status: telemetryInsideWorkspace ? .passed : .failed,
                path: telemetryPath.path,
                message: telemetryInsideWorkspace ? "Telemetry path is inside the workspace." : "Telemetry path must be inside the workspace."
            )
        )
        checks.append(
            WorkspaceValidationCheck(
                name: "repo_id_configured",
                status: repoIDConfigured ? .passed : .failed,
                path: nil,
                message: repoIDConfigured ? "Repository identifier is configured." : "Repository identifier is empty."
            )
        )
        checks.append(
            WorkspaceValidationCheck(
                name: "workspace_id_configured",
                status: workspaceIDConfigured ? .passed : .failed,
                path: nil,
                message: workspaceIDConfigured ? "Workspace identifier is configured." : "Workspace identifier is empty."
            )
        )
        checks.append(
            WorkspaceValidationCheck(
                name: "stack_configured",
                status: stackConfigured ? .passed : .failed,
                path: nil,
                message: stackConfigured ? "Stack is configured." : "Stack is empty."
            )
        )
        checks.append(
            WorkspaceValidationCheck(
                name: "machine_id_configured",
                status: machineIDConfigured ? .passed : .failed,
                path: nil,
                message: machineIDConfigured ? "Machine identifier is configured." : "Machine identifier is empty."
            )
        )

        return WorkspaceValidationReport(
            valid: checks.allSatisfy { $0.status == .passed },
            root: root.path,
            openspecRoot: openspecRoot.path,
            telemetryPath: telemetryPath.path,
            repoId: workspace.repoId,
            workspaceId: workspace.workspaceId,
            stack: workspace.stack,
            machineId: workspace.machineId,
            organizationId: workspace.organizationId,
            checks: checks
        )
    }

    public func validateSecrets() -> SecretValidationReport {
        secretResolver.validate(workspace.secretReferences)
    }

    public func resolveSecret(name: String) throws -> String {
        guard let reference = workspace.secretReferences.first(where: { $0.name == name }) else {
            throw SDDCoreError.secretMissing("Secret \(name) is not configured.")
        }
        return try secretResolver.resolve(reference)
    }

    public func runLoop(
        runId: String? = nil,
        featureSlug: String? = nil,
        intakeMarkdown: String? = nil,
        adapter: AgentAdapter? = nil,
        owner: String,
        actorType: ActorType = .agent,
        maxSteps: Int = 20
    ) throws -> WorkflowRunLoopResult {
        guard maxSteps > 0 else {
            throw SDDCoreError.invalidTransition("Run loop max steps must be greater than zero.")
        }

        let providedInputs = [runId, featureSlug, intakeMarkdown].compactMap { $0 }.count
        guard providedInputs == 1 else {
            throw SDDCoreError.invalidTransition("Provide exactly one of run_id, feature_slug, or intake_markdown.")
        }

        var result: TransitionResult
        if let runId {
            result = try nextAction(runId: runId)
        } else if let featureSlug {
            result = try startRun(featureSlug: featureSlug, adapter: adapter ?? .codex, owner: owner, actorType: actorType)
        } else if let intakeMarkdown {
            result = try startRun(intakeMarkdown: intakeMarkdown, adapter: adapter ?? .codex, owner: owner, actorType: actorType)
        } else {
            throw SDDCoreError.invalidTransition("Run loop input was not provided.")
        }

        var iterations = 1
        while iterations <= maxSteps {
            switch result.status {
            case .actionRequired:
                let invocation = try prepareExecution(runId: result.runId, adapter: adapter)
                return WorkflowRunLoopResult(
                    runId: result.runId,
                    featureSlug: result.featureSlug,
                    status: result.status,
                    phase: result.phase,
                    iterations: iterations,
                    nextAction: result,
                    invocation: invocation,
                    message: "Executable action is ready. Run the selected coding-agent adapter and submit an ExecutionAdapterResult."
                )
            case .inputRequired:
                return WorkflowRunLoopResult(
                    runId: result.runId,
                    featureSlug: result.featureSlug,
                    status: result.status,
                    phase: result.phase,
                    iterations: iterations,
                    nextAction: result,
                    invocation: nil,
                    message: "Human input is required. Submit the answer with answer_prompt."
                )
            case .approvalRequired:
                return WorkflowRunLoopResult(
                    runId: result.runId,
                    featureSlug: result.featureSlug,
                    status: result.status,
                    phase: result.phase,
                    iterations: iterations,
                    nextAction: result,
                    invocation: nil,
                    message: "Human approval is required. Submit the decision with approve_gate or reject_gate."
                )
            case .blocked:
                return WorkflowRunLoopResult(
                    runId: result.runId,
                    featureSlug: result.featureSlug,
                    status: result.status,
                    phase: result.phase,
                    iterations: iterations,
                    nextAction: result,
                    invocation: nil,
                    message: "Run is blocked. Resolve the blocker or use retry_action when ready."
                )
            case .completed:
                return WorkflowRunLoopResult(
                    runId: result.runId,
                    featureSlug: result.featureSlug,
                    status: result.status,
                    phase: result.phase,
                    iterations: iterations,
                    nextAction: result,
                    invocation: nil,
                    message: "Run is completed."
                )
            case .failed:
                return WorkflowRunLoopResult(
                    runId: result.runId,
                    featureSlug: result.featureSlug,
                    status: result.status,
                    phase: result.phase,
                    iterations: iterations,
                    nextAction: result,
                    invocation: nil,
                    message: "Run failed. Inspect the failed reason and retry when appropriate."
                )
            case .running:
                result = try nextAction(runId: result.runId)
                iterations += 1
            }
        }

        throw SDDCoreError.invalidTransition("Run loop exceeded max steps: \(maxSteps).")
    }

    public func startRun(featureSlug: String, adapter: AgentAdapter, owner: String, actorType: ActorType = .human) throws -> TransitionResult {
        try validateFeatureSlug(featureSlug)
        if let existing = try activeRun(featureSlug: featureSlug) {
            return lockHeldResult(existing)
        }
        try artifactStore.createFeatureArtifacts(featureSlug: featureSlug)
        return try createRun(featureSlug: featureSlug, adapter: adapter, owner: owner, actorType: actorType)
    }

    public func startRun(intakeMarkdown: String, adapter: AgentAdapter, owner: String, actorType: ActorType = .human) throws -> TransitionResult {
        let intake = try normalizeIntake(markdown: intakeMarkdown)
        guard let featureSlug = intake.sliceReadyRequirements.first?.featureSlug else {
            throw SDDCoreError.intakeParseFailed("Normalized intake must include at least one slice-ready requirement.")
        }
        try validateFeatureSlug(featureSlug)
        if let existing = try activeRun(featureSlug: featureSlug) {
            return lockHeldResult(existing)
        }
        try artifactStore.createFeatureArtifacts(featureSlug: featureSlug, intake: intake)
        return try createRun(featureSlug: featureSlug, adapter: adapter, owner: owner, actorType: actorType)
    }

    private func createRun(featureSlug: String, adapter: AgentAdapter, owner: String, actorType: ActorType) throws -> TransitionResult {
        let now = Date()
        let runSummary = RunSummary(
            runId: "run_\(UUID().uuidString.lowercased())",
            featureSlug: featureSlug,
            status: .actionRequired,
            currentPhase: .plan,
            activeAdapter: adapter,
            identityAttribution: workspace.identityAttribution(actorId: owner, actorType: actorType, adapter: adapter),
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
        try emit(eventName: "sdd.result.submitted", summary: summary, properties: resultSubmittedProperties(phase: phase, result: result))
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

    public func rejectGate(runId: String, phase: WorkflowPhase, rejectedBy: String, reason: String) throws -> TransitionResult {
        var summary = try artifactStore.findRunSummary(runId: runId)
        guard summary.status == .approvalRequired else {
            throw SDDCoreError.invalidTransition("Run \(runId) is not waiting for approval.")
        }
        guard summary.currentPhase == phase else {
            throw SDDCoreError.invalidTransition("Cannot reject phase \(phase.rawValue) while current phase is \(summary.currentPhase.rawValue).")
        }

        summary.status = .blocked
        summary.lock = nil
        summary.blockers.append(
            BlockerRecord(
                reason: .approvalRequired,
                message: "Approval rejected: \(reason)",
                at: Date()
            )
        )
        summary.phaseHistory.append(
            PhaseHistoryEntry(
                phase: phase,
                status: .blocked,
                at: Date(),
                note: "gate_rejected:\(phase.rawValue):\(rejectedBy)"
            )
        )

        try artifactStore.writeRunSummary(summary)
        try emit(
            eventName: "sdd.gate.rejected",
            summary: summary,
            properties: [
                "phase": phase.rawValue,
                "rejected_by": rejectedBy,
                "reason": reason
            ]
        )
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

    public func markBlocked(runId: String, reason: BlockedReason, message: String, markedBy: String) throws -> TransitionResult {
        var summary = try artifactStore.findRunSummary(runId: runId)
        guard !isTerminal(summary.status) else {
            throw SDDCoreError.invalidTransition("Run \(runId) is \(summary.status.rawValue) and cannot be marked blocked.")
        }

        summary.status = .blocked
        summary.lock = nil
        summary.blockers.append(BlockerRecord(reason: reason, message: message, at: Date()))
        summary.phaseHistory.append(
            PhaseHistoryEntry(
                phase: summary.currentPhase,
                status: .blocked,
                at: Date(),
                note: "blocked:\(reason.rawValue):\(markedBy)"
            )
        )

        try artifactStore.writeRunSummary(summary)
        try emit(
            eventName: "sdd.run.blocked",
            summary: summary,
            properties: [
                "reason": reason.rawValue,
                "marked_by": markedBy
            ]
        )
        return try nextAction(runId: runId)
    }

    public func retryAction(runId: String, owner: String) throws -> TransitionResult {
        var summary = try artifactStore.findRunSummary(runId: runId)
        guard summary.status == .blocked || summary.status == .failed else {
            throw SDDCoreError.invalidTransition("Run \(runId) is \(summary.status.rawValue) and cannot be retried.")
        }

        let now = Date()
        summary.status = .actionRequired
        summary.lock = LockInfo(owner: owner, acquiredAt: now, expiresAt: nil)
        summary.phaseHistory.append(
            PhaseHistoryEntry(
                phase: summary.currentPhase,
                status: .actionRequired,
                at: now,
                note: "retry_action:\(owner)"
            )
        )

        try artifactStore.writeRunSummary(summary)
        try emit(eventName: "sdd.action.retried", summary: summary, properties: ["owner": owner])
        return try nextAction(runId: runId)
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

    private func isPath(_ candidate: URL, inside root: URL) -> Bool {
        let rootPath = canonicalURL(root).path
        let candidatePath = canonicalURL(candidate).path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private func canonicalURL(_ url: URL) -> URL {
        var current = url.standardizedFileURL
        var missingComponents: [String] = []

        while !FileManager.default.fileExists(atPath: current.path), current.path != "/" {
            missingComponents.insert(current.lastPathComponent, at: 0)
            current.deleteLastPathComponent()
        }

        let resolvedBase = current.resolvingSymlinksInPath().standardizedFileURL
        return missingComponents.reduce(resolvedBase) { partial, component in
            partial.appendingPathComponent(component)
        }.standardizedFileURL
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

    private func resultSubmittedProperties(phase: WorkflowPhase, result: ExecutionAdapterResult) -> [String: String] {
        var properties = [
            "phase": phase.rawValue,
            "result_adapter": result.adapter.rawValue
        ]

        if let logRef = result.logRef {
            properties["log_ref"] = logRef
        }
        if !result.telemetryRefs.isEmpty {
            properties["telemetry_ref_count"] = String(result.telemetryRefs.count)
        }
        if let tokenUsage = result.tokenUsage {
            properties["token_confidence"] = tokenUsage.confidence.rawValue
            if let provider = tokenUsage.provider {
                properties["token_provider"] = provider
            }
            if let model = tokenUsage.model {
                properties["token_model"] = model
            }
            if let inputTokens = tokenUsage.inputTokens {
                properties["input_tokens"] = String(inputTokens)
            }
            if let outputTokens = tokenUsage.outputTokens {
                properties["output_tokens"] = String(outputTokens)
            }
            if let cachedTokens = tokenUsage.cachedTokens {
                properties["cached_tokens"] = String(cachedTokens)
            }
            if let reasoningTokens = tokenUsage.reasoningTokens {
                properties["reasoning_tokens"] = String(reasoningTokens)
            }
        }

        return properties
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
            identityAttribution: summary.identityAttribution,
            properties: TelemetryRedactor.redact(properties)
        )
        try telemetrySink.emit(event)
        emitMetricsAndTrace(for: event)
    }

    private func emitMetricsAndTrace(for event: TelemetryEvent) {
        let attributes = telemetryAttributes(for: event)
        metricsRecorder.incrementCounter(name: "sdd.events.emitted", by: 1, attributes: attributes)
        metricsRecorder.incrementCounter(name: "sdd.workflow.status.\(event.status.rawValue)", by: 1, attributes: attributes)
        traceRecorder.recordSpan(
            SDDTraceSpan(
                name: event.eventName,
                runId: event.runId,
                featureSlug: event.featureSlug,
                phase: event.phase,
                status: event.status,
                attributes: attributes.merging(event.properties) { current, _ in current }
            )
        )
    }

    private func telemetryAttributes(for event: TelemetryEvent) -> [String: String] {
        var attributes = [
            "event_name": event.eventName,
            "feature_slug": event.featureSlug,
            "phase": event.phase.rawValue,
            "status": event.status.rawValue,
            "interface": event.interface.rawValue,
            "repo_id": workspace.repoId,
            "workspace_id": workspace.workspaceId,
            "stack": workspace.stack,
            "actor_id": event.identityAttribution?.actorId ?? summaryFallbackActorID,
            "actor_type": event.identityAttribution?.actorType.rawValue ?? "unknown",
            "machine_id": event.identityAttribution?.machineId ?? workspace.machineId
        ]
        if let organizationId = event.identityAttribution?.organizationId ?? workspace.organizationId {
            attributes["organization_id"] = organizationId
        }
        if let adapter = event.adapter {
            attributes["adapter"] = adapter.rawValue
        }
        return attributes
    }
}

private let summaryFallbackActorID = "unknown"
