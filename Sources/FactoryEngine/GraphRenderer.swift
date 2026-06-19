import FactoryModels

/// Renders a Pipeline as a Mermaid flowchart — the "renders 1:1 to the DAG diagram" view (§5,
/// ADR-0027). Pure: a deterministic transform of spec data, no I/O and no LLM, so it is testable
/// without a run and reproducible. Works for both kinds of DAG — a build pattern (artifact edges,
/// labelled with the Schema) and an orchestration graph (`depends_on` edges, no label).
public enum GraphRenderer {
    /// A fenced Mermaid `flowchart` block for the pipeline. Every node is declared (so isolated
    /// nodes still appear and labels are controlled); each edge renders an arrow, carrying its
    /// artifact Schema as the edge label unless it is absent or the `*` wildcard.
    public static func mermaid(_ pipeline: PipelineSpec, direction: String = "TD") -> String {
        var lines = ["```mermaid", "flowchart \(direction)"]
        for node in pipeline.nodes {
            lines.append("    \(safeID(node.id))\(label(node))")
        }
        for edge in pipeline.edges {
            let schema = edge.artifact.flatMap { $0 == "*" ? nil : $0 }
            let arrow = schema.map { "-->|\($0)|" } ?? "-->"
            for from in edge.from.values {
                lines.append("    \(safeID(from)) \(arrow) \(safeID(edge.to))")
            }
        }
        lines.append("```")
        return lines.joined(separator: "\n")
    }

    /// Mermaid node ids must be identifier-safe; non-identifier characters map to `_`. The original
    /// id is preserved in the visible label, so kebab-case ids read normally.
    private static func safeID(_ id: String) -> String {
        String(id.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" })
    }

    /// The visible node label: the id, plus a second line noting the worker, that it is a slice, and
    /// its stack — whatever the node declares.
    private static func label(_ node: PipelineNode) -> String {
        var detail: [String] = []
        if let worker = node.worker, worker != node.id { detail.append(worker) }   // skip if redundant
        if node.pipeline != nil { detail.append("slice") }
        if let stack = node.stack { detail.append("[\(stack)]") }
        let second = detail.isEmpty ? "" : "<br/>\(detail.joined(separator: " "))"
        return "[\"\(node.id)\(second)\"]"
    }
}
