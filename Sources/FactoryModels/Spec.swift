import Foundation

// Declarative spec types — the data the engine interprets (architecture.md §2, §5, §7).
// These mirror the example YAML under docs/examples/sdlc-plant/. For this first slice they
// are decoded from JSON (Foundation, no deps); the SAME types load YAML via Yams later
// (ADR-0020 — decode IS structural validation, format-independent).

// MARK: - Envelope (the K8s-style apiVersion/kind/metadata/spec wrapper)

public struct SpecMetadata: Codable, Equatable, Sendable {
    public var name: String
    public var version: Int?

    public init(name: String, version: Int? = nil) {
        self.name = name
        self.version = version
    }
}

public struct SpecEnvelope<Spec: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public var apiVersion: String
    public var kind: String
    public var metadata: SpecMetadata
    public var spec: Spec

    public init(apiVersion: String, kind: String, metadata: SpecMetadata, spec: Spec) {
        self.apiVersion = apiVersion
        self.kind = kind
        self.metadata = metadata
        self.spec = spec
    }
}

// MARK: - OneOrMany (an edge's `from` may be a single node or a list of nodes)

public struct OneOrMany<Element: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public var values: [Element]

    public init(_ values: [Element]) { self.values = values }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let one = try? container.decode(Element.self) {
            values = [one]
        } else {
            values = try container.decode([Element].self)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if values.count == 1 {
            try container.encode(values[0])
        } else {
            try container.encode(values)
        }
    }
}

// MARK: - Pipeline (the typed DAG — topology lives here, §5)

public struct PipelineSpec: Codable, Equatable, Sendable {
    public var semantics: String?          // "enabler" — deps are readiness, not forced order (§6)
    public var nodes: [PipelineNode]
    public var edges: [PipelineEdge]

    public init(semantics: String? = nil, nodes: [PipelineNode], edges: [PipelineEdge]) {
        self.semantics = semantics
        self.nodes = nodes
        self.edges = edges
    }
}

public struct PipelineNode: Codable, Equatable, Sendable {
    public var id: String
    public var worker: String?             // role/worker name; nil for some node kinds
    public var kind: String?               // e.g. "join", "human" (WorkerKind)
    public var required: Bool?             // a required check node
    public var mapOver: String?            // dynamic fan-out (§10)

    public init(id: String, worker: String? = nil, kind: String? = nil,
                required: Bool? = nil, mapOver: String? = nil) {
        self.id = id
        self.worker = worker
        self.kind = kind
        self.required = required
        self.mapOver = mapOver
    }
}

public struct PipelineEdge: Codable, Equatable, Sendable {
    public var from: OneOrMany<String>
    public var to: String
    public var artifact: String?           // the Schema id carried across the edge

    public init(from: OneOrMany<String>, to: String, artifact: String? = nil) {
        self.from = from
        self.to = to
        self.artifact = artifact
    }
}

// MARK: - Worker (the typed signature — what the Scheduler type-checks edges against, §5)

public struct WorkerSpec: Codable, Equatable, Sendable {
    public var workerKind: String?
    public var consumes: [PortSpec]?
    public var produces: [PortSpec]?
    public var task: WorkerTask?           // the unit of work — a repo skill or command
    public var checks: [String]?           // gates the output must pass (check ids)
    public var model: String?              // capability tier alias (e.g. "deep-reasoning") — never a provider/model id
    public var reasoning: String?          // "minimal" | "low" | "medium" | "high"

    public init(workerKind: String? = nil, consumes: [PortSpec]? = nil, produces: [PortSpec]? = nil,
                task: WorkerTask? = nil, checks: [String]? = nil,
                model: String? = nil, reasoning: String? = nil) {
        self.workerKind = workerKind
        self.consumes = consumes
        self.produces = produces
        self.task = task
        self.checks = checks
        self.model = model
        self.reasoning = reasoning
    }
}

/// A Worker's unit of work: a repo-defined skill (surfaced via AGENTS.md / CLAUDE.md) or a
/// command that runs one. Portable across providers — never an inline prompt.
public struct WorkerTask: Codable, Equatable, Sendable {
    public var skill: String?
    public var command: String?

    public init(skill: String? = nil, command: String? = nil) {
        self.skill = skill
        self.command = command
    }
}

// MARK: - Check (a gate/eval definition — one assertion run by the CheckRunner, §8)

public struct CheckSpec: Codable, Equatable, Sendable {
    public var checkKind: String?     // "deterministic" | "judge" | "human"
    public var command: String?       // deterministic: the command to run (exit 0 == pass)
    public var required: Bool?        // a blocking gate when true (default); false scores only

    public init(checkKind: String? = nil, command: String? = nil, required: Bool? = nil) {
        self.checkKind = checkKind
        self.command = command
        self.required = required
    }
}

public struct PortSpec: Codable, Equatable, Sendable {
    public var schema: String
    public var cardinality: String?        // "one" | "many"
    public var required: Bool?

    public init(schema: String, cardinality: String? = nil, required: Bool? = nil) {
        self.schema = schema
        self.cardinality = cardinality
        self.required = required
    }
}
