import FactoryModels

/// A consumed input, with whether its Schema is currently available in the Run.
public struct RenderedInput: Codable, Equatable, Sendable {
    public var schema: String
    public var required: Bool
    public var ready: Bool

    public init(schema: String, required: Bool, ready: Bool) {
        self.schema = schema
        self.required = required
        self.ready = ready
    }
}

/// The engine's rendering of one runnable Worker — the instruction the agent executes.
/// Structured so it can be emitted as JSON for a programmatic driver, or as Markdown for a
/// human/agent reader. The engine renders; the agent does the work.
public struct WorkerInstruction: Codable, Equatable, Sendable {
    public var runId: String?
    public var node: String
    public var worker: String
    public var workerKind: String?
    public var task: WorkerTask?
    public var model: String?
    public var reasoning: String?
    public var requiredGate: Bool
    public var consumes: [RenderedInput]
    public var produces: [String]
    public var checks: [String]
    public var rework: [String]        // gates a prior attempt failed; empty on a first attempt

    public init(runId: String? = nil, node: String, worker: String, workerKind: String? = nil,
                task: WorkerTask? = nil, model: String? = nil, reasoning: String? = nil,
                requiredGate: Bool = false, consumes: [RenderedInput] = [],
                produces: [String] = [], checks: [String] = [], rework: [String] = []) {
        self.runId = runId
        self.node = node
        self.worker = worker
        self.workerKind = workerKind
        self.task = task
        self.model = model
        self.reasoning = reasoning
        self.requiredGate = requiredGate
        self.consumes = consumes
        self.produces = produces
        self.checks = checks
        self.rework = rework
    }
}

/// Renders a runnable node + its Worker into an instruction. Pure: no I/O, no state mutation.
public enum Renderer {
    /// Build the structured instruction for `node` (executed by `worker`) given current state.
    public static func instruction(node: PipelineNode, worker: WorkerSpec, state: RunState) -> WorkerInstruction {
        let consumes = (worker.consumes ?? []).map { port in
            RenderedInput(schema: port.schema,
                          required: port.required ?? false,
                          ready: state.readyArtifacts.contains(port.schema))
        }
        return WorkerInstruction(
            node: node.id,
            worker: node.worker ?? node.id,
            workerKind: worker.workerKind,
            task: worker.task,
            model: worker.model,
            reasoning: worker.reasoning,
            requiredGate: node.required ?? false,
            consumes: consumes,
            produces: (worker.produces ?? []).map(\.schema),
            checks: worker.checks ?? [],
            rework: state.failedChecks[node.id] ?? []
        )
    }

    /// Render the instruction as Markdown — what the driver agent reads and acts on.
    public static func markdown(_ instruction: WorkerInstruction) -> String {
        var lines: [String] = []
        lines.append("# Worker `\(instruction.worker)`  ·  node `\(instruction.node)`")

        var meta: [String] = []
        if let kind = instruction.workerKind { meta.append("kind: \(kind)") }
        if let model = instruction.model {
            meta.append(instruction.reasoning.map { "model: \(model) (reasoning: \($0))" } ?? "model: \(model)")
        }
        if instruction.requiredGate { meta.append("required gate") }
        if !meta.isEmpty { lines.append(meta.joined(separator: "  ·  ")) }

        if !instruction.rework.isEmpty {
            lines.append("")
            lines.append("## Rework")
            lines.append("A prior attempt failed these gates — address them this attempt:")
            for check in instruction.rework { lines.append("- \(check)") }
        }

        lines.append("")
        lines.append("## Task")
        lines.append(taskLine(instruction.task))

        lines.append("")
        lines.append("## Inputs")
        if instruction.consumes.isEmpty {
            lines.append("- (none — this is a source node)")
        } else {
            for input in instruction.consumes {
                let req = input.required ? "required" : "optional"
                let ready = input.ready ? "✓ ready" : "✗ missing"
                lines.append("- `\(input.schema)` — \(req), \(ready)")
            }
        }

        lines.append("")
        lines.append("## Produces")
        if instruction.produces.isEmpty {
            lines.append("- (nothing)")
        } else {
            for schema in instruction.produces { lines.append("- `\(schema)`") }
        }

        lines.append("")
        lines.append("## Checks (output must pass)")
        if instruction.checks.isEmpty {
            lines.append("- (none)")
        } else {
            for check in instruction.checks { lines.append("- \(check)") }
        }

        return lines.joined(separator: "\n")
    }

    private static func taskLine(_ task: WorkerTask?) -> String {
        if let skill = task?.skill { return "Run skill: `\(skill)`" }
        if let command = task?.command { return "Run command: `\(command)`" }
        return "(no task declared)"
    }
}
