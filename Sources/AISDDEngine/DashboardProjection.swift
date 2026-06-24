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
        guard let section = programSection(programDir: programDir, runStore: runStore,
                                           fileManager: fileManager) else {
            throw ProjectDashboardError.invalidProgram(programDir.path)
        }
        // The section heading is "Program · <name>"; the title equals the program metadata name, so
        // derive it by dropping the prefix the helper already applied (avoids a second SpecLoader load).
        let prefix = "Program · "
        let title = section.heading.hasPrefix(prefix)
            ? String(section.heading.dropFirst(prefix.count))
            : section.heading
        return ProjectDashboard(title: title, sections: [section])
    }

    /// Builds the one status-annotated `Program · <name>` section for a program dir, or `nil` when the
    /// program is unloadable/empty (no master `pipeline.yaml`, malformed, or no nodes). `nil` is the
    /// graceful-skip signal the whole-repo `ProjectDashboardAssembler` uses; `assemble` turns it into
    /// the `.invalidProgram` throw. Reuses the existing `matchedState`/`standardizedPath`/
    /// `featurePipelineLoader` helpers unchanged.
    static func programSection(programDir: URL, runStore: RunStore,
                               fileManager: FileManager = .default) -> GraphRenderer.DashboardSection? {
        let homeURL = programDir.standardizedFileURL
        let loader = SpecLoader()

        guard let env = try? loader.loadPipeline(atDirectory: homeURL), !env.spec.nodes.isEmpty else {
            return nil
        }

        let programName = env.metadata.name
        let match = matchedState(for: homeURL, in: runStore)
        let projection = DashboardProjection.project(
            program: env.spec,
            metadata: env.metadata,
            state: match.state,
            featurePipeline: featurePipelineLoader(programDir: homeURL, loader: loader))

        return GraphRenderer.DashboardSection(
            heading: "Program · \(programName)",
            projection: projection,
            mermaid: GraphRenderer.dashboardMermaid(env.spec, rows: projection.rows,
                                                    inheritedOwner: env.metadata.owner ?? []),
            staleRun: match.stale)
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

    /// Reconcile a program dir against the run store. First the exact-path match (S2's
    /// `resolvedPath`); on a miss, the shared best-effort fallback surfaces an unreconcilable run by
    /// trailing segment so a stale program run is attributed, not dropped.
    static func matchedState(for pipelineDir: URL, in runStore: RunStore) -> (state: RunState?, stale: Bool) {
        DashboardRunMatch.matchedState(for: pipelineDir, in: runStore)
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
            let match = matchedState(for: homeURL, in: runStore)
            let projection = DashboardProjection.project(
                pipeline: env.spec,
                metadata: env.metadata,
                state: match.state)
            buildPattern = .init(
                heading: "Build pattern · \(env.metadata.name)",
                projection: projection,
                mermaid: GraphRenderer.dashboardMermaid(env.spec, rows: projection.rows,
                                                        inheritedOwner: env.metadata.owner ?? []),
                staleRun: match.stale)
        }

        let featuresDir = homeURL.appendingPathComponent("features", isDirectory: true)
        let entries = ((try? fileManager.contentsOfDirectory(
            at: featuresDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for entry in entries {
            let name = entry.lastPathComponent
            if let env = try? loader.loadPipeline(atDirectory: entry) {
                let match = matchedState(for: entry, in: runStore)
                let projection = DashboardProjection.project(
                    pipeline: env.spec,
                    metadata: env.metadata,
                    state: match.state)
                sections.append(.init(
                    heading: "Feature · \(name)",
                    projection: projection,
                    mermaid: GraphRenderer.dashboardMermaid(env.spec, rows: projection.rows,
                                                            inheritedOwner: env.metadata.owner ?? []),
                    staleRun: match.stale))
            } else {
                sections.append(.init(heading: "Feature · \(name)", projection: emptyProjection()))
            }
        }

        let programsDir = homeURL.appendingPathComponent(Layout.programsDir, isDirectory: true)
        let programEntries = ((try? fileManager.contentsOfDirectory(
            at: programsDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for entry in programEntries {
            if let section = ProgramDashboardAssembler.programSection(
                programDir: entry, runStore: runStore, fileManager: fileManager) {
                sections.append(section)
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

    /// Reconcile a feature/build-pattern dir against the run store: exact-path match first, then the
    /// shared best-effort fallback so an unreconcilable run surfaces (with `stale: true`) instead of
    /// the feature dropping to all-pending.
    private static func matchedState(for pipelineDir: URL, in runStore: RunStore) -> (state: RunState?, stale: Bool) {
        DashboardRunMatch.matchedState(for: pipelineDir, in: runStore)
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

/// The one run⇔dir reconciliation both assemblers share. The exact-path match (S2's `resolvedPath`)
/// is tried first; only on a miss does the best-effort fallback attach an UNRECONCILABLE run — a
/// stored `pipelineDir` that is absolute and resolves nowhere on disk (S2 could neither relativize
/// nor heal it) whose trailing segment equals the target dir name — flagging it `stale`. Exact and
/// relative-resolving matches keep today's behavior and are never flagged. Pure aside from the run
/// store reads the assemblers already do; no wall clock, no git.
enum DashboardRunMatch {
    static func matchedState(for pipelineDir: URL, in runStore: RunStore) -> (state: RunState?, stale: Bool) {
        let expected = pipelineDir.standardizedFileURL.path
        let target = pipelineDir.standardizedFileURL.lastPathComponent
        let runIds = (try? runStore.runIds()) ?? []

        // (1) Exact path match — the existing, healthy/healed path. No marker.
        for runId in runIds {
            guard let meta = try? runStore.meta(of: runId),
                  resolvedPath(meta.pipelineDir, base: runStore.base) == expected
            else { continue }
            return (try? runStore.state(of: runId), false)
        }

        // (2) Best-effort: an unreconcilable run (absolute stored pipelineDir resolving nowhere)
        // whose trailing feature/program segment matches the target dir name. Attach it, flag stale.
        for runId in runIds {
            guard let meta = try? runStore.meta(of: runId),
                  isUnreconcilable(meta.pipelineDir, base: runStore.base),
                  trailingSegment(of: meta.pipelineDir) == target
            else { continue }
            return (try? runStore.state(of: runId), true)
        }

        return (nil, false)
    }

    /// Resolve a stored `RunMeta.pipelineDir` to a comparable standardized path. An ABSOLUTE stored
    /// path keeps today's exact behavior (base ignored); a RELATIVE stored path is anchored to the
    /// run-store base before standardizing, so a committed-fixture-style relative run matches on any
    /// clone.
    static func resolvedPath(_ stored: String, base: URL) -> String {
        if (stored as NSString).isAbsolutePath {
            return standardizedPath(stored)
        }
        return URL(fileURLWithPath: stored, relativeTo: base).standardizedFileURL.path
    }

    /// A stored `pipelineDir` S2 left unreconciled: it is ABSOLUTE (a relative path always resolves
    /// against the base, so S2's relativize/heal already canonicalized it) and points nowhere on
    /// disk. This is exactly the residue `RunStore.heal` returns byte-for-byte (rule 4).
    private static func isUnreconcilable(_ stored: String, base: URL) -> Bool {
        guard (stored as NSString).isAbsolutePath else { return false }
        return !FileManager.default.fileExists(atPath: standardizedPath(stored))
    }

    /// The trailing path component of a stored `pipelineDir` (the feature/program dir name), used to
    /// attribute an unreconcilable absolute pointer to its `features/<name>` / `programs/<name>` dir.
    static func trailingSegment(of stored: String) -> String {
        URL(fileURLWithPath: stored, isDirectory: true).standardizedFileURL.lastPathComponent
    }

    private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
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

/// A runnable node ranked by how many slices it would transitively unblock — its forward reachable
/// (descendant) set over the `from → to` (depends_on) edge model. S3 (attention band, top
/// unblockers) consumes this; the higher the `unblockCount`, the longer the pole that node clears.
public struct RankedRunnable: Equatable, Sendable {
    /// The runnable node's id.
    public var node: String
    /// The number of distinct slices reachable forward from `node` along depends_on edges — i.e. how
    /// many downstream slices completing this node would (transitively) help unblock.
    public var unblockCount: Int

    public init(node: String, unblockCount: Int) {
        self.node = node
        self.unblockCount = unblockCount
    }
}

/// Pure DAG analysis over a feature's slice graph: the per-feature **critical path** (longest
/// dependency chain) and a **ranking of runnable slices by transitive downstream-unblock count**.
///
/// Both functions are pure transforms of their inputs — no file, network, or wall-clock I/O — so
/// identical inputs always yield byte-identical results. They COMPUTE a projection only and render
/// nothing; sibling slices S3 (attention band → top unblockers) and S4 (detail band → critical-path
/// marking) consume the output. The edge model matches the rest of the engine: an edge
/// `from → to` is a dependency (`to` depends_on `from`), so forward adjacency (`from → to`) is the
/// "this unblocks that" direction `DashboardProjection.dependencyCount` and `Scheduler` already use.
public enum DashboardCriticalPath {
    /// The longest dependency chain (critical path) over the pipeline's slice DAG, as an ordered list
    /// of node ids from chain start to chain end. Length is measured in node count; ties at every
    /// branch (and across equal-length chains overall) are broken by ascending node id, so the result
    /// is a single stable chain. Returns `[]` for an empty pipeline. Pure / I/O-free / deterministic.
    public static func criticalPath(_ pipeline: PipelineSpec) -> [String] {
        let adjacency = forwardAdjacency(pipeline)
        let nodeIds = pipeline.nodes.map { $0.id }
        guard !nodeIds.isEmpty else { return [] }

        // Memoized longest forward chain starting at each node. The DAG guarantees termination; the
        // per-node memo keeps this linear. Tie-break: among equally long successor chains pick the one
        // whose successor id is smallest, so the whole path is determined by id order alone.
        var memo: [String: [String]] = [:]
        func longestFrom(_ node: String) -> [String] {
            if let cached = memo[node] { return cached }
            let successors = (adjacency[node] ?? []).sorted()
            var best: [String] = []
            for successor in successors {
                let candidate = longestFrom(successor)
                if candidate.count > best.count {
                    best = candidate
                }
                // Equal length keeps the first (smallest-id) successor, since `successors` is sorted
                // and we only replace on a strictly longer chain.
            }
            let chain = [node] + best
            memo[node] = chain
            return chain
        }

        // Consider every node as a potential chain start so a longest path that does not begin at a
        // source is still found; pick the longest, breaking overall ties by ascending start id.
        var result: [String] = []
        for node in nodeIds.sorted() {
            let chain = longestFrom(node)
            if chain.count > result.count {
                result = chain
            }
        }
        return result
    }

    /// The currently runnable slices ranked by their transitive downstream-unblock count — the size of
    /// each runnable node's forward reachable (descendant) set over the depends_on edges. The runnable
    /// set is taken from `Scheduler.runnable(state ?? RunState(), pipeline)`, the same source of truth
    /// `DashboardProjection.project` uses, so the ranking never drifts from the dashboard's runnable
    /// count. Sorted by descending `unblockCount`, then ascending node id. Pure / I/O-free /
    /// deterministic — `state` defaults to an empty `RunState` (everything with no deps is runnable).
    public static func runnableRanking(_ pipeline: PipelineSpec, state: RunState? = nil) -> [RankedRunnable] {
        let adjacency = forwardAdjacency(pipeline)
        let runnable = Scheduler.runnable(state ?? RunState(), pipeline)

        var memo: [String: Set<String>] = [:]
        func descendants(_ node: String) -> Set<String> {
            if let cached = memo[node] { return cached }
            var reached: Set<String> = []
            for successor in adjacency[node] ?? [] {
                reached.insert(successor)
                reached.formUnion(descendants(successor))
            }
            memo[node] = reached
            return reached
        }

        return runnable
            .map { RankedRunnable(node: $0, unblockCount: descendants($0).count) }
            .sorted { lhs, rhs in
                if lhs.unblockCount != rhs.unblockCount { return lhs.unblockCount > rhs.unblockCount }
                return lhs.node < rhs.node
            }
    }

    /// Forward adjacency `from → to` (each dependency edge points from a prerequisite to the node that
    /// depends on it). A `join`-style edge with several `from` sources contributes one `source → to`
    /// arc per source, matching the edge semantics `Scheduler.runnable` and `dependencyCount` use.
    private static func forwardAdjacency(_ pipeline: PipelineSpec) -> [String: [String]] {
        var adjacency: [String: [String]] = [:]
        for edge in pipeline.edges {
            for source in edge.from.values {
                adjacency[source, default: []].append(edge.to)
            }
        }
        return adjacency
    }
}
