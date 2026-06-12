import FactoryModels

/// A static (load-time) validation finding.
public struct ValidationIssue: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case unknownWorker      // a node references a worker that does not exist
        case unknownNode        // an edge references a node that does not exist
        case edgeTypeMismatch   // an edge's Schema is not produced/consumed by its endpoints
        case unknownCheck       // a worker references a check that does not exist
        case cycle              // the dependency graph is not acyclic
        case missingPipelineRef // a pipeline (slice) node has no sub-pipeline reference
    }

    public var kind: Kind
    public var message: String

    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }
}

/// Static checks that run at load time, before any token is spent (architecture.md §5):
/// referential integrity + edge type-compatibility against Worker signatures.
public enum SpecValidator {
    public static func validate(pipeline: PipelineSpec, workers: [String: WorkerSpec],
                                checks: [String: CheckSpec] = [:]) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        let nodeByID = Dictionary(uniqueKeysWithValues: pipeline.nodes.map { ($0.id, $0) })

        // 1. Reference checks per node: a worker node resolves its worker + that worker's checks;
        //    a slice node (it expands into a sub-pipeline) must name the sub-pipeline.
        for node in pipeline.nodes {
            if node.kind == "pipeline" || node.pipeline != nil {
                if (node.pipeline ?? "").isEmpty {
                    issues.append(.init(kind: .missingPipelineRef,
                                        message: "slice node '\(node.id)' has no 'pipeline' reference"))
                }
                continue
            }
            guard let workerName = node.worker else { continue }
            guard let worker = workers[workerName] else {
                issues.append(.init(kind: .unknownWorker,
                                    message: "node '\(node.id)' references unknown worker '\(workerName)'"))
                continue
            }
            for check in worker.checks ?? [] where checks[check] == nil {
                issues.append(.init(kind: .unknownCheck,
                                    message: "worker '\(workerName)' references unknown check '\(check)'"))
            }
        }

        // 2. Every edge references existing nodes.
        for edge in pipeline.edges {
            for from in edge.from.values where nodeByID[from] == nil {
                issues.append(.init(kind: .unknownNode, message: "edge references unknown source node '\(from)'"))
            }
            if nodeByID[edge.to] == nil {
                issues.append(.init(kind: .unknownNode, message: "edge references unknown target node '\(edge.to)'"))
            }
        }

        // 3. Edge type-check: the producer must produce the Schema and the consumer must consume it.
        for edge in pipeline.edges {
            guard let schema = edge.artifact, schema != "*" else { continue }

            if let toNode = nodeByID[edge.to], let workerName = toNode.worker, let worker = workers[workerName] {
                let consumed = (worker.consumes ?? []).map(\.schema)
                if !consumed.contains(schema) {
                    issues.append(.init(kind: .edgeTypeMismatch,
                                        message: "node '\(edge.to)' (worker '\(workerName)') does not consume '\(schema)'"))
                }
            }

            for from in edge.from.values {
                if let fromNode = nodeByID[from], let workerName = fromNode.worker, let worker = workers[workerName] {
                    let produced = (worker.produces ?? []).map(\.schema)
                    if !produced.contains(schema) {
                        issues.append(.init(kind: .edgeTypeMismatch,
                                            message: "node '\(from)' (worker '\(workerName)') does not produce '\(schema)'"))
                    }
                }
            }
        }

        // 4. The graph must be acyclic — a dependency cycle would never become runnable (§5).
        if let cycle = firstCycle(pipeline) {
            issues.append(.init(kind: .cycle,
                                message: "dependency cycle: \(cycle.joined(separator: " → "))"))
        }

        return issues
    }

    /// Returns the nodes of one cycle (for the message), or nil if the graph is acyclic.
    /// DFS with a recursion stack; edges run from each `from` node to the `to` node.
    private static func firstCycle(_ pipeline: PipelineSpec) -> [String]? {
        var successors: [String: [String]] = [:]
        for edge in pipeline.edges {
            for from in edge.from.values { successors[from, default: []].append(edge.to) }
        }
        var color: [String: Int] = [:]   // 0/absent = unvisited, 1 = on stack, 2 = done
        var stack: [String] = []

        func visit(_ node: String) -> [String]? {
            color[node] = 1
            stack.append(node)
            for next in successors[node] ?? [] {
                switch color[next] {
                case 1: return Array(stack[(stack.firstIndex(of: next) ?? 0)...]) + [next]
                case 2: continue
                default: if let found = visit(next) { return found }
                }
            }
            stack.removeLast()
            color[node] = 2
            return nil
        }

        for node in pipeline.nodes where color[node.id] == nil {
            if let found = visit(node.id) { return found }
        }
        return nil
    }
}
