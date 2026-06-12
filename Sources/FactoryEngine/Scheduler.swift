import FactoryModels

/// The pure planner (architecture.md §6). Readiness is computed over the Pipeline's central
/// edge list — the Scheduler never polls Workers or auto-discovers connections.
public enum Scheduler {
    /// Which nodes are runnable right now: not yet completed, and for every incoming edge the
    /// source node(s) are complete **and** any declared Artifact is ready. Nodes with no incoming
    /// edges (sources) are runnable from the start. This one rule unifies both kinds of DAG:
    /// artifact edges (a pattern pipeline) and pure dependency edges (a slice graph's `depends_on`,
    /// which carry no Artifact); it also correctly gates a `join` over `[a, b, …]`.
    public static func runnable(_ state: RunState, _ pipeline: PipelineSpec) -> [String] {
        pipeline.nodes.compactMap { node in
            guard !state.completedNodes.contains(node.id) else { return nil }

            let incoming = pipeline.edges.filter { $0.to == node.id }
            let sourcesComplete = incoming.allSatisfy { edge in
                edge.from.values.allSatisfy { state.completedNodes.contains($0) }
            }
            let artifactsReady = incoming
                .compactMap { $0.artifact }
                .filter { $0 != "*" }
                .allSatisfy { state.readyArtifacts.contains($0) }

            return (sourcesComplete && artifactsReady) ? node.id : nil
        }
    }

    /// Whether every node in the pipeline has completed (the whole graph is done).
    public static func isComplete(_ state: RunState, _ pipeline: PipelineSpec) -> Bool {
        pipeline.nodes.allSatisfy { state.completedNodes.contains($0.id) }
    }

    /// The single node `next` should dispense: an already-in-progress runnable node
    /// (so re-running `next` before `submit` re-renders the same work, not a new node),
    /// else the first runnable node in declaration order. `nil` when nothing is runnable.
    public static func pick(_ state: RunState, _ pipeline: PipelineSpec) -> String? {
        let ready = runnable(state, pipeline)
        return ready.first { state.inProgressNodes.contains($0) } ?? ready.first
    }
}
