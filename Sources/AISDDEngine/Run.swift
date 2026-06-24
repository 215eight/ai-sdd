import AISDDModels

/// The state of a Run — a projection of the RunEvent log (architecture.md §6). Minimal for
/// this slice: which Schemas are ready, and which nodes have completed.
public struct RunState: Equatable, Sendable {
    public var readyArtifacts: Set<String>      // Schema ids currently available
    public var completedNodes: Set<String>
    public var inProgressNodes: Set<String>     // dispensed by `next`, not yet submitted
    public var failedChecks: [String: [String]] // node → checks its last attempt failed (rework context)
    public var reworkRounds: [String: Int]      // node whose gate failed → how many rework rounds it drove (§9 bound)
    public var escalatedNodes: Set<String>      // gate kept failing past the bound → parked for a human
    public var slices: [String: RunState]       // per-slice sub-pipeline state (a node that expands)

    public init(readyArtifacts: Set<String> = [], completedNodes: Set<String> = [],
                inProgressNodes: Set<String> = [], failedChecks: [String: [String]] = [:],
                reworkRounds: [String: Int] = [:], escalatedNodes: Set<String> = [],
                slices: [String: RunState] = [:]) {
        self.readyArtifacts = readyArtifacts
        self.completedNodes = completedNodes
        self.inProgressNodes = inProgressNodes
        self.failedChecks = failedChecks
        self.reworkRounds = reworkRounds
        self.escalatedNodes = escalatedNodes
        self.slices = slices
    }
}

/// An append-only event. (This slice models the two events the Scheduler/Reducer need;
/// the full set — started/gate/blocked/approval/etc. — comes later.) `Codable` so the
/// `RunStore` can persist one file per event.
public indirect enum RunEvent: Codable, Equatable, Sendable {
    case runStarted(seedArtifacts: [String])                       // pipeline inputs available at start
    case nodeStarted(node: String)                                 // `next` dispensed this node's work
    case checkFailed(node: String, checks: [String])               // a submit's required gates failed → self-rework
    case nodeCompleted(node: String, producedArtifacts: [String])  // a node finished and produced these
    // §9 rework: a node's gate failed and indicts upstream inputs — route to the producers that made
    // them, invalidate that subtree (so it re-runs), and carry the failed checks as their context.
    // Payloads are resolved by the engine from topology + the verdict artifact; the Reducer just folds.
    case reworkRouted(failedNode: String, producers: [String],
                      invalidatedNodes: [String], invalidatedArtifacts: [String], checks: [String])
    case escalated(node: String, checks: [String])                 // gate kept failing past the bound → human
    case scoped(slice: String, event: RunEvent)                    // an event inside a slice's sub-pipeline
}

/// Who an event is attributed to — the git identity captured at append time, or `unowned` when no
/// git identity is resolvable (no guess). Persisted only on the `RunEventRecord` wrapper, never on
/// the pure `RunEvent`, so the Reducer fold is unaffected.
public enum RunEventOwner: Codable, Equatable, Sendable {
    case identified(name: String, email: String)
    case unowned
}

/// The persisted shape of a single appended event: the pure `RunEvent` plus optional metadata
/// stamped at the `RunStore.append` boundary — an RFC 3339 UTC (`…Z`) `at` timestamp and an
/// `owner`. Metadata is optional so legacy bare-`RunEvent` files keep decoding (decision
/// `optional-fields-for-backcompat`); the recursive `scoped` event carries no per-level metadata
/// (decision `metadata-via-wrapper-record`).
public struct RunEventRecord: Codable, Equatable, Sendable {
    public var event: RunEvent
    public var at: String?          // RFC 3339 UTC, `Z`-suffixed; nil ⇒ unknown (legacy)
    public var owner: RunEventOwner?

    public init(event: RunEvent, at: String? = nil, owner: RunEventOwner? = nil) {
        self.event = event
        self.at = at
        self.owner = owner
    }
}

/// The pure event→state fold (architecture.md §6). Replayable: same events ⇒ same state.
public enum Reducer {
    public static func reduce(_ state: RunState, _ event: RunEvent) -> RunState {
        var next = state
        switch event {
        case let .runStarted(seedArtifacts):
            next.readyArtifacts.formUnion(seedArtifacts)
        case let .nodeStarted(node):
            next.inProgressNodes.insert(node)
        case let .checkFailed(node, checks):
            // The attempt ended in failure: the node leaves "in progress" and returns to
            // runnable, carrying its failed gates so the next render shows the rework context.
            next.inProgressNodes.remove(node)
            next.failedChecks[node] = checks
        case let .nodeCompleted(node, producedArtifacts):
            next.inProgressNodes.remove(node)
            next.failedChecks[node] = nil
            next.completedNodes.insert(node)
            next.readyArtifacts.formUnion(producedArtifacts)
        case let .reworkRouted(failedNode, producers, invalidatedNodes, invalidatedArtifacts, checks):
            // The failed node (e.g. a reviewer) is not the one reworking — its producers are. Drop
            // the failed node from "in progress", invalidate the affected subtree so it re-runs
            // (build-system-style scoped invalidation), and hand the producers the failed checks as
            // their rework context. Count the round on the failed node so the bound can escalate.
            next.inProgressNodes.remove(failedNode)
            next.failedChecks[failedNode] = nil
            next.completedNodes.subtract(invalidatedNodes)
            next.readyArtifacts.subtract(invalidatedArtifacts)
            for producer in producers { next.failedChecks[producer] = checks }
            next.reworkRounds[failedNode, default: 0] += 1
        case let .escalated(node, checks):
            next.inProgressNodes.remove(node)
            next.escalatedNodes.insert(node)
            next.failedChecks[node] = checks
        case let .scoped(slice, inner):
            // Route the event into that slice's sub-pipeline state (same fold, one level down).
            next.slices[slice] = reduce(next.slices[slice] ?? RunState(), inner)
        }
        return next
    }

    public static func reduce(_ state: RunState, events: [RunEvent]) -> RunState {
        events.reduce(state, reduce)
    }
}
