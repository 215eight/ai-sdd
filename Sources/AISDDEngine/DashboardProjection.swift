import AISDDModels

public enum DashboardStatus: String, Codable, CaseIterable, Equatable, Sendable {
    case done
    case inProgress = "in-progress"
    case rework
    case escalated
    case runnable
    case pending
}

public enum DashboardNextActionHint: String, Codable, Equatable, Sendable {
    case none
    case continueWork = "continue-work"
    case fixFailedChecks = "fix-failed-checks"
    case humanIntervention = "human-intervention"
    case startWork = "start-work"
    case waitingOnDependencies = "waiting-on-dependencies"
}

public struct DashboardProjectionRow: Codable, Equatable, Sendable {
    public var node: String
    public var stack: String?
    public var owner: String
    public var lane: String?
    public var milestone: String?
    public var dependencyCount: Int
    public var status: DashboardStatus
    public var nextActionHint: DashboardNextActionHint

    public init(node: String, stack: String?, owner: String, lane: String?, milestone: String?,
                dependencyCount: Int, status: DashboardStatus, nextActionHint: DashboardNextActionHint) {
        self.node = node
        self.stack = stack
        self.owner = owner
        self.lane = lane
        self.milestone = milestone
        self.dependencyCount = dependencyCount
        self.status = status
        self.nextActionHint = nextActionHint
    }
}

public struct DashboardProjectionSummary: Codable, Equatable, Sendable {
    public var totalFeatureCount: Int
    public var totalNodeCount: Int
    public var doneCount: Int
    public var statusTotals: [DashboardStatus: Int]

    public init(totalFeatureCount: Int, totalNodeCount: Int, doneCount: Int,
                statusTotals: [DashboardStatus: Int]) {
        self.totalFeatureCount = totalFeatureCount
        self.totalNodeCount = totalNodeCount
        self.doneCount = doneCount
        self.statusTotals = statusTotals
    }
}

public struct DashboardProjectionResult: Codable, Equatable, Sendable {
    public var rows: [DashboardProjectionRow]
    public var summary: DashboardProjectionSummary

    public init(rows: [DashboardProjectionRow], summary: DashboardProjectionSummary) {
        self.rows = rows
        self.summary = summary
    }
}

public enum DashboardProjection {
    public static func project(pipeline: PipelineSpec, metadata: SpecMetadata,
                               state: RunState? = nil) -> DashboardProjectionResult {
        let runState = state ?? RunState()
        let runnable = Set(Scheduler.runnable(runState, pipeline))
        let rows = pipeline.nodes.map { node in
            let status = status(for: node.id, state: state, runnable: runnable)
            return DashboardProjectionRow(
                node: node.id,
                stack: node.stack,
                owner: ownerLabel(for: node, metadata: metadata),
                lane: metadata.factory,
                milestone: metadata.correlation,
                dependencyCount: dependencyCount(for: node.id, in: pipeline),
                status: status,
                nextActionHint: nextActionHint(for: status))
        }
        let totals = statusTotals(rows)
        return DashboardProjectionResult(
            rows: rows,
            summary: DashboardProjectionSummary(
                totalFeatureCount: 1,
                totalNodeCount: rows.count,
                doneCount: totals[.done, default: 0],
                statusTotals: totals))
    }

    private static func status(for node: String, state: RunState?, runnable: Set<String>) -> DashboardStatus {
        guard let state else {
            return runnable.contains(node) ? .runnable : .pending
        }
        if state.escalatedNodes.contains(node) { return .escalated }
        if state.failedChecks[node] != nil { return .rework }
        if state.inProgressNodes.contains(node) { return .inProgress }
        if state.completedNodes.contains(node) { return .done }
        if runnable.contains(node) { return .runnable }
        return .pending
    }

    private static func nextActionHint(for status: DashboardStatus) -> DashboardNextActionHint {
        switch status {
        case .done:
            return .none
        case .inProgress:
            return .continueWork
        case .rework:
            return .fixFailedChecks
        case .escalated:
            return .humanIntervention
        case .runnable:
            return .startWork
        case .pending:
            return .waitingOnDependencies
        }
    }

    private static func dependencyCount(for node: String, in pipeline: PipelineSpec) -> Int {
        Set(pipeline.edges.filter { $0.to == node }.flatMap { $0.from.values }).count
    }

    private static func ownerLabel(for node: PipelineNode, metadata: SpecMetadata) -> String {
        if let owner = node.owner, !owner.isEmpty { return owner.joined(separator: ", ") }
        if let owner = metadata.owner, !owner.isEmpty { return owner.joined(separator: ", ") }
        if !metadata.name.isEmpty { return metadata.name }
        return node.stack ?? ""
    }

    private static func statusTotals(_ rows: [DashboardProjectionRow]) -> [DashboardStatus: Int] {
        var totals = Dictionary(uniqueKeysWithValues: DashboardStatus.allCases.map { ($0, 0) })
        for row in rows {
            totals[row.status, default: 0] += 1
        }
        return totals
    }
}
