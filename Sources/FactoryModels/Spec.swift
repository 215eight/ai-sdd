import Foundation

// Declarative spec types — the data the engine interprets (architecture.md §2, §5, §7).
// These mirror the example YAML under docs/examples/sdlc-plant/. For this first slice they
// are decoded from JSON (Foundation, no deps); the SAME types load YAML via Yams later
// (ADR-0020 — decode IS structural validation, format-independent).

// MARK: - Envelope (the K8s-style apiVersion/kind/metadata/spec wrapper)

public struct SpecMetadata: Codable, Equatable, Sendable {
    public var name: String
    public var version: Int?
    // Fragment tags for cross-repo graph aggregation (ADR-0027). All optional & additive; only a
    // feature pipeline sets them, every other spec kind ignores them.
    public var correlation: String?      // milestone/program join-key — fragments aggregate by this
    public var factory: String?          // discipline lane: requirements | design | code | deploy
    public var owner: [String]?          // accountable people (the feature lead; 1+)
    public var origin: Origin?           // where this fragment lives (repo + git ref + path)

    public init(name: String, version: Int? = nil, correlation: String? = nil,
                factory: String? = nil, owner: [String]? = nil, origin: Origin? = nil) {
        self.name = name
        self.version = version
        self.correlation = correlation
        self.factory = factory
        self.owner = owner
        self.origin = origin
    }
}

/// Where a fragment lives, for multi-repo composition (ADR-0027). Versioned git-natively: `tag`
/// carries the semver (semantic compatibility), `hash` the exact commit (identity + staleness).
public struct Origin: Codable, Equatable, Sendable {
    public var repo: String?
    public var tag: String?
    public var hash: String?
    public var path: String?

    public init(repo: String? = nil, tag: String? = nil, hash: String? = nil, path: String? = nil) {
        self.repo = repo
        self.tag = tag
        self.hash = hash
        self.path = path
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
    public var kind: String?               // e.g. "join", "human", "pipeline" (WorkerKind)
    public var required: Bool?             // a required check node
    public var mapOver: String?            // dynamic fan-out (§10)
    public var pipeline: String?           // a sub-pipeline workspace this node expands into (a slice)
    public var stack: String?              // the slice's stack — its late-bound specialization (§7)
    public var owner: [String]?            // the IC(s) driving this slice; inherits the feature lead if absent (ADR-0027)

    public init(id: String, worker: String? = nil, kind: String? = nil,
                required: Bool? = nil, mapOver: String? = nil,
                pipeline: String? = nil, stack: String? = nil, owner: [String]? = nil) {
        self.id = id
        self.worker = worker
        self.kind = kind
        self.required = required
        self.mapOver = mapOver
        self.pipeline = pipeline
        self.stack = stack
        self.owner = owner
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

// MARK: - Schema (an Artifact's type: structure + invariants → deterministic gates)
//
// A Schema describes a produced Artifact so that deterministic checks can be derived from it.
// `fields` + `invariants` are the structural (Tier-1) part the `SchemaValidator` enforces;
// the semantic (Tier-2) and judge (Tier-3) tiers compile to command/judge CheckSpecs elsewhere.

public struct SchemaSpec: Codable, Equatable, Sendable {
    public var handle: String?                  // file · files · git-ref · figma · url · …
    public var format: String?                  // yaml · json · markdown · code · …
    public var scope: String?                   // "internal" | "contract"
    public var fields: [String: FieldSpec]?     // structured shape (when format is structured)

    public init(handle: String? = nil, format: String? = nil, scope: String? = nil,
                fields: [String: FieldSpec]? = nil) {
        self.handle = handle
        self.format = format
        self.scope = scope
        self.fields = fields
    }
}

public struct FieldSpec: Codable, Equatable, Sendable {
    public var type: String?                    // string · number · bool · enum · path · list · object
    public var required: Bool?
    public var invariants: [Invariant]?

    public init(type: String? = nil, required: Bool? = nil, invariants: [Invariant]? = nil) {
        self.type = type
        self.required = required
        self.invariants = invariants
    }
}

/// A declarative predicate over a field's value. Structured (not a string DSL) so it compiles
/// to a deterministic assertion unambiguously.
public struct Invariant: Codable, Equatable, Sendable {
    public var nonEmpty: Bool?                  // string/list/object must be non-empty
    public var eq: String?                      // scalar must equal this
    public var matches: String?                 // scalar must match this regex
    public var all: ItemPredicate?              // every element of a list must satisfy this

    public init(nonEmpty: Bool? = nil, eq: String? = nil, matches: String? = nil,
                all: ItemPredicate? = nil) {
        self.nonEmpty = nonEmpty
        self.eq = eq
        self.matches = matches
        self.all = all
    }
}

/// The per-element predicate of an `all` invariant. `field` targets a subkey of object items
/// (omit for scalar lists).
public struct ItemPredicate: Codable, Equatable, Sendable {
    public var field: String?
    public var nonEmpty: Bool?
    public var eq: String?
    public var matches: String?

    public init(field: String? = nil, nonEmpty: Bool? = nil, eq: String? = nil, matches: String? = nil) {
        self.field = field
        self.nonEmpty = nonEmpty
        self.eq = eq
        self.matches = matches
    }
}
