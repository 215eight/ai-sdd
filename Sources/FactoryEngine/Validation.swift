import FactoryModels

/// A static (load-time) validation finding.
public struct ValidationIssue: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case unknownWorker      // a node references a worker that does not exist
        case unknownNode        // an edge references a node that does not exist
        case edgeTypeMismatch   // an edge's Schema is not produced/consumed by its endpoints
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
    public static func validate(pipeline: PipelineSpec, workers: [String: WorkerSpec]) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        let nodeByID = Dictionary(uniqueKeysWithValues: pipeline.nodes.map { ($0.id, $0) })

        // 1. Every node.worker reference resolves.
        for node in pipeline.nodes {
            if let worker = node.worker, workers[worker] == nil {
                issues.append(.init(kind: .unknownWorker,
                                    message: "node '\(node.id)' references unknown worker '\(worker)'"))
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

        return issues
    }
}
