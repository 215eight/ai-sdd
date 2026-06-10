import FactoryModels

/// The pure planner (architecture.md §6). Readiness is computed over the Pipeline's central
/// edge list — the Scheduler never polls Workers or auto-discovers connections.
public enum Scheduler {
    /// Which nodes are runnable right now: not yet completed, and every incoming-edge
    /// artifact is ready. Nodes with no incoming edges (sources) are runnable from the start.
    public static func runnable(_ state: RunState, _ pipeline: PipelineSpec) -> [String] {
        pipeline.nodes.compactMap { node in
            guard !state.completedNodes.contains(node.id) else { return nil }

            let requiredInputs = pipeline.edges
                .filter { $0.to == node.id }
                .compactMap { $0.artifact }
                .filter { $0 != "*" }

            let ready = requiredInputs.allSatisfy { state.readyArtifacts.contains($0) }
            return ready ? node.id : nil
        }
    }
}
