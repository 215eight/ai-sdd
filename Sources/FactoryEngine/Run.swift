import FactoryModels

/// The state of a Run — a projection of the RunEvent log (architecture.md §6). Minimal for
/// this slice: which Schemas are ready, and which nodes have completed.
public struct RunState: Equatable, Sendable {
    public var readyArtifacts: Set<String>      // Schema ids currently available
    public var completedNodes: Set<String>
    public var inProgressNodes: Set<String>     // dispensed by `next`, not yet submitted
    public var failedChecks: [String: [String]] // node → checks its last attempt failed (rework context)

    public init(readyArtifacts: Set<String> = [], completedNodes: Set<String> = [],
                inProgressNodes: Set<String> = [], failedChecks: [String: [String]] = [:]) {
        self.readyArtifacts = readyArtifacts
        self.completedNodes = completedNodes
        self.inProgressNodes = inProgressNodes
        self.failedChecks = failedChecks
    }
}

/// An append-only event. (This slice models the two events the Scheduler/Reducer need;
/// the full set — started/gate/blocked/approval/etc. — comes later.) `Codable` so the
/// `RunStore` can persist one file per event.
public enum RunEvent: Codable, Equatable, Sendable {
    case runStarted(seedArtifacts: [String])                       // pipeline inputs available at start
    case nodeStarted(node: String)                                 // `next` dispensed this node's work
    case checkFailed(node: String, checks: [String])               // a submit's required gates failed → rework
    case nodeCompleted(node: String, producedArtifacts: [String])  // a node finished and produced these
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
        }
        return next
    }

    public static func reduce(_ state: RunState, events: [RunEvent]) -> RunState {
        events.reduce(state, reduce)
    }
}
