import FactoryModels

/// §9 / ADR-0011 rework routing. A failing required gate on a node (a reviewer's verdict) does not
/// re-run that node — that would just re-judge unchanged work. Instead it routes back to the
/// Worker(s) that produced the node's *consumed inputs*, re-runs them with the failure as context,
/// and scope-invalidates the affected subtree so it rebuilds. Which input is at fault is data in the
/// verdict artifact (`rework[].target`); the engine resolves that against the pipeline topology here.
/// Pure (topology + set arithmetic) so it is testable without a run.
public enum Rework {
    /// The bound on rework rounds for one failing gate before it escalates to a human.
    public static let maxRounds = 3

    /// What to do with a failed verdict gate: route the rework upstream, or escalate to a human.
    public enum Disposition: Equatable, Sendable {
        case route(Routing)   // re-run the indicted inputs' producers (bounded)
        case escalate         // bound spent, or nowhere to route → a human decides
    }

    /// The §9 policy in one pure decision: within the round bound and with a resolvable target,
    /// route upstream; otherwise escalate. Keeps the bound + routing logic testable without a run.
    public static func decide(round: Int, failedNode: String, indicted: [String],
                              pipeline: PipelineSpec, produces: [String: [String]]) -> Disposition {
        guard round < maxRounds,
              let routing = route(failedNode: failedNode, indicted: indicted,
                                  pipeline: pipeline, produces: produces)
        else { return .escalate }
        return .route(routing)
    }

    /// The resolved routing: who re-runs, what is invalidated.
    public struct Routing: Equatable, Sendable {
        public var producers: [String]            // nodes to re-run (producers of the indicted inputs)
        public var invalidatedNodes: [String]     // producers + their downstream closure (all re-run)
        public var invalidatedArtifacts: [String] // schemas the invalidated nodes produced (drop from ready)

        public init(producers: [String], invalidatedNodes: [String], invalidatedArtifacts: [String]) {
            self.producers = producers
            self.invalidatedNodes = invalidatedNodes
            self.invalidatedArtifacts = invalidatedArtifacts
        }
    }

    /// Route a failed gate on `failedNode` to the producers of the `indicted` input schemas.
    /// `produces` maps each node id → the schemas it produces (for scope invalidation). Returns nil
    /// when no incoming edge carries an indicted schema — the caller then escalates (nowhere to route).
    public static func route(failedNode: String, indicted: [String], pipeline: PipelineSpec,
                             produces: [String: [String]]) -> Routing? {
        let indictedSet = Set(indicted)
        var producers: [String] = []
        for edge in pipeline.edges where edge.to == failedNode {
            guard let artifact = edge.artifact, indictedSet.contains(artifact) else { continue }
            for from in edge.from.values where !producers.contains(from) { producers.append(from) }
        }
        guard !producers.isEmpty else { return nil }

        let invalidated = downstreamClosure(of: producers, in: pipeline)   // includes the producers
        let artifacts = invalidated.flatMap { produces[$0] ?? [] }
        return Routing(producers: producers,
                       invalidatedNodes: invalidated.sorted(),
                       invalidatedArtifacts: Array(Set(artifacts)).sorted())
    }

    /// Every node reachable from `seeds` along edges, including the seeds themselves — the subtree a
    /// re-run of the producers makes stale (so it must rebuild).
    private static func downstreamClosure(of seeds: [String], in pipeline: PipelineSpec) -> [String] {
        var successors: [String: [String]] = [:]
        for edge in pipeline.edges {
            for from in edge.from.values { successors[from, default: []].append(edge.to) }
        }
        var seen = Set(seeds)
        var stack = seeds
        while let node = stack.popLast() {
            for next in successors[node] ?? [] where seen.insert(next).inserted { stack.append(next) }
        }
        return Array(seen)
    }
}
