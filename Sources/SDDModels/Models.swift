import Foundation

public enum SDDConstants {
    public static let schemaVersion = "1.0.0"
    public static let protocolVersion = "0.1.0"
    public static let coreVersion = "0.1.0"
}

public enum WorkflowStatus: String, Codable, CaseIterable {
    case actionRequired = "action_required"
    case inputRequired = "input_required"
    case approvalRequired = "approval_required"
    case running
    case blocked
    case completed
    case failed
}

public enum WorkflowPhase: String, Codable, CaseIterable {
    case plan
    case implement
    case review
}

public enum ActorType: String, Codable, CaseIterable {
    case human
    case agent
    case ci
    case service
}

public enum AgentAdapter: String, Codable, CaseIterable {
    case codex
    case claudeCode = "claude-code"
}

public enum InterfaceMode: String, Codable, CaseIterable {
    case cli
    case mcp
    case auto
}

public enum ActionKind: String, Codable, CaseIterable {
    case produceArtifact = "produce_artifact"
    case executeTasks = "execute_tasks"
    case reviewChanges = "review_changes"
    case requestInput = "request_input"
    case requestApproval = "request_approval"
    case none
}

public enum AdapterResultStatus: String, Codable, CaseIterable {
    case ok
    case failed
    case blocked
}

public enum TokenAttributionConfidence: String, Codable, CaseIterable {
    case directRequest = "direct_request"
    case sessionScoped = "session_scoped"
    case timeWindow = "time_window"
    case unattributed
}

public enum BlockedReason: String, Codable, CaseIterable {
    case missingInput = "missing_input"
    case missingSecret = "missing_secret"
    case missingArtifact = "missing_artifact"
    case approvalRequired = "approval_required"
    case lockHeld = "lock_held"
    case policyViolation = "policy_violation"
    case adapterUnavailable = "adapter_unavailable"
    case unsupportedStack = "unsupported_stack"
}

public enum FailedReason: String, Codable, CaseIterable {
    case adapterExecutionFailed = "adapter_execution_failed"
    case artifactValidationFailed = "artifact_validation_failed"
    case transitionEvaluationFailed = "transition_evaluation_failed"
    case telemetryWriteFailed = "telemetry_write_failed"
    case openspecWriteFailed = "openspec_write_failed"
    case unexpectedError = "unexpected_error"
}

public struct ArtifactRef: Codable, Equatable {
    public var type: String
    public var path: String

    public init(type: String, path: String) {
        self.type = type
        self.path = path
    }
}

public enum ArtifactState: String, Codable, CaseIterable {
    case missing
    case empty
    case placeholder
    case ready
}

public enum ArtifactValidationIssueReason: String, Codable, CaseIterable {
    case missing
    case empty
    case placeholder
}

public struct ArtifactDescriptor: Codable, Equatable {
    public var ref: ArtifactRef
    public var required: Bool
    public var description: String

    public init(ref: ArtifactRef, required: Bool, description: String) {
        self.ref = ref
        self.required = required
        self.description = description
    }
}

public struct ArtifactContent: Codable, Equatable {
    public var ref: ArtifactRef
    public var content: String
    public var byteCount: Int

    public init(ref: ArtifactRef, content: String, byteCount: Int) {
        self.ref = ref
        self.content = content
        self.byteCount = byteCount
    }
}

public struct ArtifactStatus: Codable, Equatable {
    public var ref: ArtifactRef
    public var required: Bool
    public var state: ArtifactState
    public var byteCount: Int?

    public init(ref: ArtifactRef, required: Bool, state: ArtifactState, byteCount: Int?) {
        self.ref = ref
        self.required = required
        self.state = state
        self.byteCount = byteCount
    }
}

public struct ArtifactValidationIssue: Codable, Equatable {
    public var ref: ArtifactRef
    public var reason: ArtifactValidationIssueReason
    public var message: String

    public init(ref: ArtifactRef, reason: ArtifactValidationIssueReason, message: String) {
        self.ref = ref
        self.reason = reason
        self.message = message
    }
}

public struct ArtifactValidationReport: Codable, Equatable {
    public var featureSlug: String
    public var valid: Bool
    public var artifacts: [ArtifactStatus]
    public var issues: [ArtifactValidationIssue]

    public init(featureSlug: String, valid: Bool, artifacts: [ArtifactStatus], issues: [ArtifactValidationIssue]) {
        self.featureSlug = featureSlug
        self.valid = valid
        self.artifacts = artifacts
        self.issues = issues
    }
}

public struct LockInfo: Codable, Equatable {
    public var owner: String
    public var acquiredAt: Date
    public var expiresAt: Date?

    public init(owner: String, acquiredAt: Date, expiresAt: Date?) {
        self.owner = owner
        self.acquiredAt = acquiredAt
        self.expiresAt = expiresAt
    }
}

public struct PhaseHistoryEntry: Codable, Equatable {
    public var phase: WorkflowPhase
    public var status: WorkflowStatus
    public var at: Date
    public var note: String?

    public init(phase: WorkflowPhase, status: WorkflowStatus, at: Date, note: String?) {
        self.phase = phase
        self.status = status
        self.at = at
        self.note = note
    }
}

public struct ApprovalRecord: Codable, Equatable {
    public var gateId: String
    public var phase: WorkflowPhase
    public var approvedBy: String
    public var approvedAt: Date

    public init(gateId: String, phase: WorkflowPhase, approvedBy: String, approvedAt: Date) {
        self.gateId = gateId
        self.phase = phase
        self.approvedBy = approvedBy
        self.approvedAt = approvedAt
    }
}

public struct BlockerRecord: Codable, Equatable {
    public var reason: BlockedReason
    public var message: String
    public var at: Date

    public init(reason: BlockedReason, message: String, at: Date) {
        self.reason = reason
        self.message = message
        self.at = at
    }
}

public struct TelemetryRef: Codable, Equatable {
    public var eventId: String
    public var traceId: String?

    public init(eventId: String, traceId: String?) {
        self.eventId = eventId
        self.traceId = traceId
    }
}

public struct TokenAttribution: Codable, Equatable {
    public var provider: String?
    public var model: String?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cachedTokens: Int?
    public var reasoningTokens: Int?
    public var confidence: TokenAttributionConfidence

    public init(
        provider: String?,
        model: String?,
        inputTokens: Int?,
        outputTokens: Int?,
        cachedTokens: Int?,
        reasoningTokens: Int?,
        confidence: TokenAttributionConfidence
    ) {
        self.provider = provider
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedTokens = cachedTokens
        self.reasoningTokens = reasoningTokens
        self.confidence = confidence
    }
}

public struct IdentityAttribution: Codable, Equatable {
    public var actorId: String
    public var actorType: ActorType
    public var agentAdapter: AgentAdapter?
    public var repoId: String
    public var workspaceId: String
    public var machineId: String
    public var organizationId: String?

    public init(
        actorId: String,
        actorType: ActorType,
        agentAdapter: AgentAdapter?,
        repoId: String,
        workspaceId: String,
        machineId: String,
        organizationId: String?
    ) {
        self.actorId = actorId
        self.actorType = actorType
        self.agentAdapter = agentAdapter
        self.repoId = repoId
        self.workspaceId = workspaceId
        self.machineId = machineId
        self.organizationId = organizationId
    }
}

public struct RunSummary: Codable, Equatable {
    public var runId: String
    public var featureSlug: String
    public var status: WorkflowStatus
    public var currentPhase: WorkflowPhase
    public var activeAdapter: AgentAdapter
    public var lock: LockInfo?
    public var phaseHistory: [PhaseHistoryEntry]
    public var approvals: [ApprovalRecord]
    public var blockers: [BlockerRecord]
    public var telemetryRefs: [TelemetryRef]
    public var tokenUsageSummary: [TokenAttribution]

    public init(
        runId: String,
        featureSlug: String,
        status: WorkflowStatus,
        currentPhase: WorkflowPhase,
        activeAdapter: AgentAdapter,
        lock: LockInfo?,
        phaseHistory: [PhaseHistoryEntry],
        approvals: [ApprovalRecord],
        blockers: [BlockerRecord],
        telemetryRefs: [TelemetryRef],
        tokenUsageSummary: [TokenAttribution]
    ) {
        self.runId = runId
        self.featureSlug = featureSlug
        self.status = status
        self.currentPhase = currentPhase
        self.activeAdapter = activeAdapter
        self.lock = lock
        self.phaseHistory = phaseHistory
        self.approvals = approvals
        self.blockers = blockers
        self.telemetryRefs = telemetryRefs
        self.tokenUsageSummary = tokenUsageSummary
    }
}

public struct WorkspaceContext: Codable, Equatable {
    public var repo: String
    public var stack: String

    public init(repo: String, stack: String) {
        self.repo = repo
        self.stack = stack
    }
}

public enum IntakeType: String, Codable, CaseIterable {
    case partnerChallenge = "partner_challenge"
    case prd
}

public enum AcceptanceSurface: String, Codable, CaseIterable {
    case none
    case uiUserWorkflow = "ui_user_workflow"
    case publicAPI = "public_api"
    case cliWorkflow = "cli_workflow"
    case operatorWorkflow = "operator_workflow"
}

public enum SliceStatus: String, Codable, CaseIterable {
    case pending
}

public struct IntakeDocument: Codable, Equatable {
    public var schemaVersion: String
    public var intakeType: IntakeType
    public var title: String
    public var sourceId: String?
    public var owner: String?
    public var body: String

    public init(
        schemaVersion: String = SDDConstants.schemaVersion,
        intakeType: IntakeType,
        title: String,
        sourceId: String?,
        owner: String?,
        body: String
    ) {
        self.schemaVersion = schemaVersion
        self.intakeType = intakeType
        self.title = title
        self.sourceId = sourceId
        self.owner = owner
        self.body = body
    }
}

public struct FeatureCatalogEntry: Codable, Equatable {
    public var featureSlug: String
    public var title: String
    public var description: String

    public init(featureSlug: String, title: String, description: String) {
        self.featureSlug = featureSlug
        self.title = title
        self.description = description
    }
}

public struct DependencyEdge: Codable, Equatable {
    public var fromFeatureSlug: String
    public var toFeatureSlug: String

    public init(fromFeatureSlug: String, toFeatureSlug: String) {
        self.fromFeatureSlug = fromFeatureSlug
        self.toFeatureSlug = toFeatureSlug
    }
}

public struct StackAssignment: Codable, Equatable {
    public var featureSlug: String
    public var stack: String

    public init(featureSlug: String, stack: String) {
        self.featureSlug = featureSlug
        self.stack = stack
    }
}

public struct SliceExecutionStatus: Codable, Equatable {
    public var featureSlug: String
    public var status: SliceStatus

    public init(featureSlug: String, status: SliceStatus) {
        self.featureSlug = featureSlug
        self.status = status
    }
}

public struct SliceReadyRequirement: Codable, Equatable {
    public var featureSlug: String
    public var title: String
    public var body: String
    public var acceptanceSurface: AcceptanceSurface
    public var alternativesRequired: Bool

    public init(
        featureSlug: String,
        title: String,
        body: String,
        acceptanceSurface: AcceptanceSurface,
        alternativesRequired: Bool
    ) {
        self.featureSlug = featureSlug
        self.title = title
        self.body = body
        self.acceptanceSurface = acceptanceSurface
        self.alternativesRequired = alternativesRequired
    }
}

public struct NormalizedIntake: Codable, Equatable {
    public var schemaVersion: String
    public var intakeType: IntakeType
    public var title: String
    public var sourceId: String?
    public var owner: String?
    public var productIntent: String
    public var featureCatalog: [FeatureCatalogEntry]
    public var dependencyGraph: [DependencyEdge]
    public var stackAssignments: [StackAssignment]
    public var closedDecisions: [String]
    public var executionStatus: [SliceExecutionStatus]
    public var sliceReadyRequirements: [SliceReadyRequirement]

    public init(
        schemaVersion: String = SDDConstants.schemaVersion,
        intakeType: IntakeType,
        title: String,
        sourceId: String?,
        owner: String?,
        productIntent: String,
        featureCatalog: [FeatureCatalogEntry],
        dependencyGraph: [DependencyEdge],
        stackAssignments: [StackAssignment],
        closedDecisions: [String],
        executionStatus: [SliceExecutionStatus],
        sliceReadyRequirements: [SliceReadyRequirement]
    ) {
        self.schemaVersion = schemaVersion
        self.intakeType = intakeType
        self.title = title
        self.sourceId = sourceId
        self.owner = owner
        self.productIntent = productIntent
        self.featureCatalog = featureCatalog
        self.dependencyGraph = dependencyGraph
        self.stackAssignments = stackAssignments
        self.closedDecisions = closedDecisions
        self.executionStatus = executionStatus
        self.sliceReadyRequirements = sliceReadyRequirements
    }
}

public struct TransitionInput: Codable, Equatable {
    public var runSummary: RunSummary
    public var artifactRefs: [ArtifactRef]
    public var latestSubmittedResult: ExecutionAdapterResult?
    public var workspaceContext: WorkspaceContext

    public init(
        runSummary: RunSummary,
        artifactRefs: [ArtifactRef],
        latestSubmittedResult: ExecutionAdapterResult?,
        workspaceContext: WorkspaceContext
    ) {
        self.runSummary = runSummary
        self.artifactRefs = artifactRefs
        self.latestSubmittedResult = latestSubmittedResult
        self.workspaceContext = workspaceContext
    }
}

public struct WorkflowAction: Codable, Equatable {
    public var kind: ActionKind
    public var instruction: String
    public var requiredInputs: [ArtifactRef]
    public var requiredOutputs: [ArtifactRef]

    public init(
        kind: ActionKind,
        instruction: String,
        requiredInputs: [ArtifactRef],
        requiredOutputs: [ArtifactRef]
    ) {
        self.kind = kind
        self.instruction = instruction
        self.requiredInputs = requiredInputs
        self.requiredOutputs = requiredOutputs
    }
}

public struct CompletionContract: Codable, Equatable {
    public var submitPhase: WorkflowPhase
    public var requiresHumanApproval: Bool

    public init(submitPhase: WorkflowPhase, requiresHumanApproval: Bool) {
        self.submitPhase = submitPhase
        self.requiresHumanApproval = requiresHumanApproval
    }
}

public struct TransitionResult: Codable, Equatable {
    public var schemaVersion: String
    public var runId: String
    public var featureSlug: String
    public var status: WorkflowStatus
    public var phase: WorkflowPhase
    public var agentRole: String?
    public var action: WorkflowAction?
    public var completionContract: CompletionContract?
    public var blockedReason: BlockedReason?
    public var failedReason: FailedReason?

    public init(
        schemaVersion: String = SDDConstants.schemaVersion,
        runId: String,
        featureSlug: String,
        status: WorkflowStatus,
        phase: WorkflowPhase,
        agentRole: String?,
        action: WorkflowAction?,
        completionContract: CompletionContract?,
        blockedReason: BlockedReason?,
        failedReason: FailedReason?
    ) {
        self.schemaVersion = schemaVersion
        self.runId = runId
        self.featureSlug = featureSlug
        self.status = status
        self.phase = phase
        self.agentRole = agentRole
        self.action = action
        self.completionContract = completionContract
        self.blockedReason = blockedReason
        self.failedReason = failedReason
    }
}

public struct ExecutionAdapterResult: Codable, Equatable {
    public var adapter: AgentAdapter
    public var status: AdapterResultStatus
    public var artifactRefs: [ArtifactRef]
    public var logRef: String?
    public var telemetryRefs: [TelemetryRef]
    public var tokenUsage: TokenAttribution?
    public var error: String?

    public init(
        adapter: AgentAdapter,
        status: AdapterResultStatus,
        artifactRefs: [ArtifactRef],
        logRef: String?,
        telemetryRefs: [TelemetryRef],
        tokenUsage: TokenAttribution?,
        error: String?
    ) {
        self.adapter = adapter
        self.status = status
        self.artifactRefs = artifactRefs
        self.logRef = logRef
        self.telemetryRefs = telemetryRefs
        self.tokenUsage = tokenUsage
        self.error = error
    }
}

public struct ExecutionAdapterInvocation: Codable, Equatable {
    public var schemaVersion: String
    public var adapter: AgentAdapter
    public var runId: String
    public var featureSlug: String
    public var phase: WorkflowPhase
    public var agentRole: String
    public var prompt: String
    public var requiredInputs: [ArtifactRef]
    public var requiredOutputs: [ArtifactRef]
    public var completionContract: CompletionContract
    public var submitCommand: String

    public init(
        schemaVersion: String = SDDConstants.schemaVersion,
        adapter: AgentAdapter,
        runId: String,
        featureSlug: String,
        phase: WorkflowPhase,
        agentRole: String,
        prompt: String,
        requiredInputs: [ArtifactRef],
        requiredOutputs: [ArtifactRef],
        completionContract: CompletionContract,
        submitCommand: String
    ) {
        self.schemaVersion = schemaVersion
        self.adapter = adapter
        self.runId = runId
        self.featureSlug = featureSlug
        self.phase = phase
        self.agentRole = agentRole
        self.prompt = prompt
        self.requiredInputs = requiredInputs
        self.requiredOutputs = requiredOutputs
        self.completionContract = completionContract
        self.submitCommand = submitCommand
    }
}

public struct TelemetryEvent: Codable, Equatable {
    public var eventId: String
    public var eventName: String
    public var runId: String
    public var featureSlug: String
    public var phase: WorkflowPhase
    public var status: WorkflowStatus
    public var adapter: AgentAdapter?
    public var interface: InterfaceMode
    public var timestamp: Date
    public var properties: [String: String]

    public init(
        eventId: String,
        eventName: String,
        runId: String,
        featureSlug: String,
        phase: WorkflowPhase,
        status: WorkflowStatus,
        adapter: AgentAdapter?,
        interface: InterfaceMode,
        timestamp: Date,
        properties: [String: String]
    ) {
        self.eventId = eventId
        self.eventName = eventName
        self.runId = runId
        self.featureSlug = featureSlug
        self.phase = phase
        self.status = status
        self.adapter = adapter
        self.interface = interface
        self.timestamp = timestamp
        self.properties = properties
    }
}

public struct Capabilities: Codable, Equatable {
    public var schemaVersion: String
    public var protocolVersion: String
    public var coreVersion: String
    public var supportedCommands: [String]
    public var supportedOperations: [String]
    public var supportedOutputModes: [String]
    public var supportedInterfaceModes: [InterfaceMode]
    public var compatibility: String

    public init(
        schemaVersion: String = SDDConstants.schemaVersion,
        protocolVersion: String = SDDConstants.protocolVersion,
        coreVersion: String = SDDConstants.coreVersion,
        supportedCommands: [String],
        supportedOperations: [String],
        supportedOutputModes: [String],
        supportedInterfaceModes: [InterfaceMode],
        compatibility: String
    ) {
        self.schemaVersion = schemaVersion
        self.protocolVersion = protocolVersion
        self.coreVersion = coreVersion
        self.supportedCommands = supportedCommands
        self.supportedOperations = supportedOperations
        self.supportedOutputModes = supportedOutputModes
        self.supportedInterfaceModes = supportedInterfaceModes
        self.compatibility = compatibility
    }
}

public enum WorkspaceValidationCheckStatus: String, Codable, CaseIterable {
    case passed
    case failed
}

public struct WorkspaceValidationCheck: Codable, Equatable {
    public var name: String
    public var status: WorkspaceValidationCheckStatus
    public var path: String?
    public var message: String

    public init(name: String, status: WorkspaceValidationCheckStatus, path: String?, message: String) {
        self.name = name
        self.status = status
        self.path = path
        self.message = message
    }
}

public struct WorkspaceValidationReport: Codable, Equatable {
    public var schemaVersion: String
    public var valid: Bool
    public var root: String
    public var openspecRoot: String
    public var telemetryPath: String
    public var repoId: String
    public var workspaceId: String
    public var stack: String
    public var checks: [WorkspaceValidationCheck]

    public init(
        schemaVersion: String = SDDConstants.schemaVersion,
        valid: Bool,
        root: String,
        openspecRoot: String,
        telemetryPath: String,
        repoId: String,
        workspaceId: String,
        stack: String,
        checks: [WorkspaceValidationCheck]
    ) {
        self.schemaVersion = schemaVersion
        self.valid = valid
        self.root = root
        self.openspecRoot = openspecRoot
        self.telemetryPath = telemetryPath
        self.repoId = repoId
        self.workspaceId = workspaceId
        self.stack = stack
        self.checks = checks
    }
}
