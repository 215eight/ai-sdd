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
    // A gate marker (program-tier milestone-gate node), distinct from `milestone` (the correlation
    // join-key). Defaulted to false and decoded as false when absent, so the project-tier projection
    // and existing serialized rows are unchanged.
    public var isMilestone: Bool

    public init(node: String, stack: String?, owner: String, lane: String?, milestone: String?,
                dependencyCount: Int, status: DashboardStatus, nextActionHint: DashboardNextActionHint,
                isMilestone: Bool = false) {
        self.node = node
        self.stack = stack
        self.owner = owner
        self.lane = lane
        self.milestone = milestone
        self.dependencyCount = dependencyCount
        self.status = status
        self.nextActionHint = nextActionHint
        self.isMilestone = isMilestone
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        node = try container.decode(String.self, forKey: .node)
        stack = try container.decodeIfPresent(String.self, forKey: .stack)
        owner = try container.decode(String.self, forKey: .owner)
        lane = try container.decodeIfPresent(String.self, forKey: .lane)
        milestone = try container.decodeIfPresent(String.self, forKey: .milestone)
        dependencyCount = try container.decode(Int.self, forKey: .dependencyCount)
        status = try container.decode(DashboardStatus.self, forKey: .status)
        nextActionHint = try container.decode(DashboardNextActionHint.self, forKey: .nextActionHint)
        isMilestone = try container.decodeIfPresent(Bool.self, forKey: .isMilestone) ?? false
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
    /// A program dir has no loadable/valid master `pipeline.yaml` (missing, malformed, or empty of
    /// nodes). Analogous to `.noGraphs`, but for the program tier: a missing run or a broken
    /// sub-pipeline degrades silently — only a genuinely unloadable program reaches this.
    case invalidProgram(String)

    public var errorDescription: String? {
        switch self {
        case let .noGraphs(path):
            return "no dashboard graphs at '\(path)' — expected a pipeline.yaml and/or a features/ folder"
        case let .invalidProgram(path):
            return "no loadable program pipeline at '\(path)' — expected a pipeline.yaml with at least one node"
        }
    }
}

/// Assembles the PROGRAM-tier dashboard: loads a program's master `pipeline.yaml`, matches its run
/// by `pipelineDir`, descends into each feature node's sub-pipeline for the rollup, and emits one
/// status-annotated master-graph section. File-aware sibling of `ProjectDashboardAssembler` (a
/// missing run or a broken sub-pipeline degrades; only an unloadable/empty program throws).
public enum ProgramDashboardAssembler {
    public static func assemble(programDir: URL, runStore: RunStore,
                                fileManager: FileManager = .default) throws -> ProjectDashboard {
        let homeURL = programDir.standardizedFileURL
        let loader = SpecLoader()

        guard let env = try? loader.loadPipeline(atDirectory: homeURL), !env.spec.nodes.isEmpty else {
            throw ProjectDashboardError.invalidProgram(programDir.path)
        }

        let programName = env.metadata.name
        let projection = DashboardProjection.project(
            program: env.spec,
            metadata: env.metadata,
            state: matchedState(for: homeURL, in: runStore),
            featurePipeline: featurePipelineLoader(programDir: homeURL, loader: loader))

        let section = GraphRenderer.DashboardSection(
            heading: "Program · \(programName)",
            projection: projection,
            mermaid: GraphRenderer.dashboardMermaid(env.spec, rows: projection.rows,
                                                    inheritedOwner: env.metadata.owner ?? []))
        return ProjectDashboard(title: programName, sections: [section])
    }

    /// A sub-pipeline loader closure for `DashboardProjection.project(program:…)`: for a `kind ==
    /// "pipeline"` node it resolves `node.pipeline` relative to `programDir` and `try?`-loads it,
    /// returning nil when `node.pipeline` is absent or the load throws (graceful degradation).
    private static func featurePipelineLoader(programDir: URL, loader: SpecLoader)
        -> (PipelineNode) -> (spec: PipelineSpec, metadata: SpecMetadata)? {
        { node in
            guard node.kind == "pipeline", let relative = node.pipeline else { return nil }
            let subDir = programDir.appendingPathComponent(relative).standardizedFileURL
            guard let env = try? loader.loadPipeline(atDirectory: subDir) else { return nil }
            return (env.spec, env.metadata)
        }
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
}

public enum ProjectDashboardAssembler {
    public static func assemble(factoryDir: URL, runStore: RunStore,
                                fileManager: FileManager = .default) throws -> ProjectDashboard {
        let homeURL = factoryDir.standardizedFileURL
        var sections: [GraphRenderer.DashboardSection] = []
        var title = homeURL.lastPathComponent
        let loader = SpecLoader()

        var buildPattern: GraphRenderer.DashboardSection?
        if let env = try? loader.loadPipeline(atDirectory: homeURL) {
            title = env.metadata.name
            let projection = DashboardProjection.project(
                pipeline: env.spec,
                metadata: env.metadata,
                state: matchedState(for: homeURL, in: runStore))
            buildPattern = .init(
                heading: "Build pattern · \(env.metadata.name)",
                projection: projection,
                mermaid: GraphRenderer.dashboardMermaid(env.spec, rows: projection.rows,
                                                        inheritedOwner: env.metadata.owner ?? []))
        }

        let featuresDir = homeURL.appendingPathComponent("features", isDirectory: true)
        let entries = ((try? fileManager.contentsOfDirectory(
            at: featuresDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for entry in entries {
            let name = entry.lastPathComponent
            if let env = try? loader.loadPipeline(atDirectory: entry) {
                let projection = DashboardProjection.project(
                    pipeline: env.spec,
                    metadata: env.metadata,
                    state: matchedState(for: entry, in: runStore))
                sections.append(.init(
                    heading: "Feature · \(name)",
                    projection: projection,
                    mermaid: GraphRenderer.dashboardMermaid(env.spec, rows: projection.rows,
                                                            inheritedOwner: env.metadata.owner ?? [])))
            } else {
                sections.append(.init(heading: "Feature · \(name)", projection: emptyProjection()))
            }
        }

        if let buildPattern, sections.isEmpty || containsActiveWork(buildPattern.projection) {
            sections.append(buildPattern)
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

    private static func containsActiveWork(_ projection: DashboardProjectionResult) -> Bool {
        projection.rows.contains { row in
            row.status == .inProgress || row.status == .rework || row.status == .escalated
        }
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

    /// A pure PROGRAM-tier rollup: maps each program node (feature ⇔ kind == "pipeline",
    /// milestone/gate ⇔ worker == "milestone-gate") to one row and aggregates the same summary
    /// shape as the project-tier projection. `featurePipeline` injects sub-pipeline loading so the
    /// engine stays pure (returns nil ⇒ degrade to program-tier signals). No file IO, no rendering.
    public static func project(program: PipelineSpec, metadata: SpecMetadata, state: RunState? = nil,
                               featurePipeline: (PipelineNode) -> (spec: PipelineSpec, metadata: SpecMetadata)? = { _ in nil })
        -> DashboardProjectionResult {
        let runState = state ?? RunState()
        let runnable = Set(Scheduler.runnable(runState, program))
        let rows = program.nodes.map { node -> DashboardProjectionRow in
            let isMilestone = node.kind != "pipeline" && node.worker == "milestone-gate"
            let nodeStatus: DashboardStatus
            if node.kind == "pipeline" {
                nodeStatus = featureStatus(for: node, state: state, runnable: runnable,
                                           featurePipeline: featurePipeline)
            } else {
                // Milestone/gate (and any other plain node): the existing plain-node precedence.
                nodeStatus = status(for: node.id, state: state, runnable: runnable)
            }
            return DashboardProjectionRow(
                node: node.id,
                stack: node.stack,
                owner: ownerLabel(for: node, metadata: metadata),
                lane: metadata.factory,
                milestone: metadata.correlation,
                dependencyCount: dependencyCount(for: node.id, in: program),
                status: nodeStatus,
                nextActionHint: nextActionHint(for: nodeStatus),
                isMilestone: isMilestone)
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

    /// Roll up a feature node (kind == "pipeline") to a single status by precedence:
    /// escalated → rework → top-level done → descend & collapse the sub-pipeline → program-tier readiness.
    private static func featureStatus(for node: PipelineNode, state: RunState?, runnable: Set<String>,
                                      featurePipeline: (PipelineNode) -> (spec: PipelineSpec, metadata: SpecMetadata)?)
        -> DashboardStatus {
        if let state {
            if state.escalatedNodes.contains(node.id) { return .escalated }
            if state.failedChecks[node.id] != nil { return .rework }
            if state.completedNodes.contains(node.id) { return .done }
        }
        if let sub = featurePipeline(node) {
            let subResult = project(pipeline: sub.spec, metadata: sub.metadata,
                                    state: state?.slices[node.id])
            let started: Set<DashboardStatus> = [.done, .inProgress, .rework, .escalated]
            if !subResult.rows.isEmpty, subResult.rows.allSatisfy({ $0.status == .done }) {
                return .done
            }
            if subResult.rows.contains(where: { started.contains($0.status) }) {
                return .inProgress
            }
        }
        return runnable.contains(node.id) ? .runnable : .pending
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
