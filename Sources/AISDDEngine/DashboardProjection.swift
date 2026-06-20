import Foundation
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

public struct ProjectDashboard: Equatable, Sendable {
    public var title: String
    public var sections: [GraphRenderer.DashboardSection]

    public init(title: String, sections: [GraphRenderer.DashboardSection]) {
        self.title = title
        self.sections = sections
    }
}

public enum ProjectDashboardError: Error, Equatable, LocalizedError, Sendable {
    case noGraphs(String)

    public var errorDescription: String? {
        switch self {
        case let .noGraphs(path):
            return "no dashboard graphs at '\(path)' — expected a pipeline.yaml and/or a features/ folder"
        }
    }
}

public enum ProjectDashboardAssembler {
    public static func assemble(factoryDir: URL, runStore: RunStore,
                                fileManager: FileManager = .default) throws -> ProjectDashboard {
        let homeURL = factoryDir.standardizedFileURL
        var sections: [GraphRenderer.DashboardSection] = []
        var title = homeURL.lastPathComponent
        let loader = SpecLoader()

        if let env = try? loader.loadPipeline(atDirectory: homeURL) {
            title = env.metadata.name
            sections.append(.init(
                heading: "Build pattern · \(env.metadata.name)",
                projection: DashboardProjection.project(
                    pipeline: env.spec,
                    metadata: env.metadata,
                    state: matchedState(for: homeURL, in: runStore))))
        }

        let featuresDir = homeURL.appendingPathComponent("features", isDirectory: true)
        let entries = ((try? fileManager.contentsOfDirectory(
            at: featuresDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for entry in entries {
            let name = entry.lastPathComponent
            if let env = try? loader.loadPipeline(atDirectory: entry) {
                sections.append(.init(
                    heading: "Feature · \(name)",
                    projection: DashboardProjection.project(
                        pipeline: env.spec,
                        metadata: env.metadata,
                        state: matchedState(for: entry, in: runStore))))
            } else {
                sections.append(.init(heading: "Feature · \(name)", projection: emptyProjection()))
            }
        }

        guard !sections.isEmpty else {
            throw ProjectDashboardError.noGraphs(factoryDir.path)
        }
        return ProjectDashboard(title: title, sections: sections)
    }

    private static func matchedState(for pipelineDir: URL, in runStore: RunStore) -> RunState? {
        let expected = pipelineDir.standardizedFileURL.path
        for runId in (try? runStore.runIds()) ?? [] {
            guard let meta = try? runStore.meta(of: runId),
                  standardizedPath(meta.pipelineDir) == expected
            else { continue }
            return try? runStore.state(of: runId)
        }
        return nil
    }

    private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }

    private static func emptyProjection() -> DashboardProjectionResult {
        DashboardProjectionResult(
            rows: [],
            summary: DashboardProjectionSummary(
                totalFeatureCount: 0,
                totalNodeCount: 0,
                doneCount: 0,
                statusTotals: Dictionary(uniqueKeysWithValues: DashboardStatus.allCases.map { ($0, 0) })))
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
