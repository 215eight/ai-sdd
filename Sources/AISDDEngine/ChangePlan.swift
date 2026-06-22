import Foundation
import AISDDModels
import Yams

/// The blast-radius tier of a changed factory artifact (ADR-0030/0031). Ordered `refresh < local <
/// contract < frozen` so the highest tier present drives the later CLI exit code via `Comparable`.
/// `frozen` is the top tier: a change whose path matches a `.ai-sdd/locks.yaml` glob is promoted to
/// it after base classification (see `ChangePlan.init`).
public enum Tier: Int, Comparable, Sendable {
    case refresh = 0   // conventions / skills — agent context, no graph edge changes
    case local = 1     // workers / pipeline / checks — affects this pipeline only
    case contract = 2  // schemas — a typed edge contract; may affect every consumer
    case frozen = 4    // a locked path (locks.yaml) — the top tier; the CLI slice hard-blocks it

    public static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A flag attached to a per-change classification, surfacing a special case the later CLI acts on.
public enum ChangeFlag: String, Equatable, Sendable {
    /// A *deleted* schema that still has consumers — a breaking removal (parent D2). The now-dangling
    /// consumers stay listed.
    case breakingRemoval
    /// An *added* schema with zero consumers — nothing depends on it yet, so it should not block on an
    /// ack (parent D3). Pairs with the `"0 consumers (new)"` blast-radius label.
    case nonAckBlocking
    /// The changed path matched a `.ai-sdd/locks.yaml` glob (ADR-0031). It is promoted to the `frozen`
    /// tier and the matched glob's reason is carried on `ChangeClassification.lockReason`.
    case locked
}

/// One entry of the `.ai-sdd/locks.yaml` manifest (ADR-0031): a path-prefix glob and the
/// human-readable reason the matched path(s) are frozen. The file is a top-level list of these.
/// Globs are path-prefix + optional trailing `*`, scoped under `.ai-sdd/` (no fnmatch/regex).
public struct LockEntry: Codable, Equatable, Sendable {
    public var glob: String
    public var reason: String

    public init(glob: String, reason: String) {
        self.glob = glob
        self.reason = reason
    }
}

/// One pipeline consumer of a contract (schema): the pipeline node id paired with the worker name it
/// runs. A single worker reused across nodes yields one entry per node.
public struct ChangeConsumer: Equatable, Sendable {
    public var node: String
    public var worker: String

    public init(node: String, worker: String) {
        self.node = node
        self.worker = worker
    }
}

/// The classification of a single changed artifact: its path/status, the tier it lands in, the
/// contract consumers it touches (empty for non-contract tiers), and any special-case flags.
public struct ChangeClassification: Equatable, Sendable {
    public var path: String
    public var status: ArtifactChange.Status
    public var tier: Tier
    public var consumers: [ChangeConsumer]
    public var flags: [ChangeFlag]
    /// `true` only for an "other non-runtime `.ai-sdd/`" path that matched no known role — it lands at
    /// `local` but is labeled unclassified.
    public var unclassified: Bool
    /// A human-readable blast-radius label, e.g. `"0 consumers (new)"` for an added 0-consumer schema.
    public var blastRadius: String?
    /// The matched lock glob's human-readable reason, set only when this change was promoted to
    /// `frozen` (carries `.locked`); `nil` otherwise. Mirrors the optional `blastRadius`.
    public var lockReason: String?

    public init(path: String, status: ArtifactChange.Status, tier: Tier,
                consumers: [ChangeConsumer] = [], flags: [ChangeFlag] = [],
                unclassified: Bool = false, blastRadius: String? = nil,
                lockReason: String? = nil) {
        self.path = path
        self.status = status
        self.tier = tier
        self.consumers = consumers
        self.flags = flags
        self.unclassified = unclassified
        self.blastRadius = blastRadius
        self.lockReason = lockReason
    }
}

/// Deterministically classifies a list of changed `.ai-sdd/` artifacts by blast-radius tier, grounded
/// in path role and — for contract (schema) changes — the loaded spec graph. No model, no content
/// heuristics: tier comes from the changed path's role, consumers come from the pipeline/worker graph
/// loaded through the existing `SpecLoader.loadBundle` (the same load path `validate` uses, so there
/// is no second parser). Per parent D5 this is an `AISDDEngine` runtime type, not an `AISDDModels`
/// spec type. It takes the `[ArtifactChange]` list (injected) plus the `.ai-sdd` dir URL, so it is
/// fully unit-testable against a fixture factory dir with no git.
public struct ChangePlan: Sendable {
    /// The classified changes, in the same order as the injected input.
    public let classifications: [ChangeClassification]

    /// Classify `changes`. `homeDirectory` is the `.ai-sdd/` workspace dir — used to load the bundle
    /// for consumer resolution when any change is a contract (schema) change. If the bundle fails to
    /// load (invalid graph), contract changes still classify as `contract` with no resolved consumers;
    /// refusing on an invalid graph is the CLI slice's concern, not this engine type's.
    public init(changes: [ArtifactChange], homeDirectory: URL, loader: SpecLoader = SpecLoader()) {
        self.init(changes: changes, homeDirectory: homeDirectory,
                  locks: try? Self.loadLocks(homeDirectory: homeDirectory), loader: loader)
    }

    /// Designated init taking the lock manifest directly — the injection seam tests use so they can
    /// pass a fixture lock list (or `nil` for "no locks file") with no real file dependency. `nil`
    /// and `[]` both mean "no promotion". A present-but-malformed file surfaces a decode error from
    /// the convenience init's loader (which the CLI slice will route); here the list is already loaded.
    public init(changes: [ArtifactChange], homeDirectory: URL, locks: [LockEntry]?,
                loader: SpecLoader = SpecLoader()) {
        // Resolve the graph lazily: only load the bundle when a schema change actually needs it.
        var cachedGraph: (pipeline: PipelineSpec, workers: [String: WorkerSpec])?? = nil
        func graph() -> (pipeline: PipelineSpec, workers: [String: WorkerSpec])? {
            if let cached = cachedGraph { return cached }
            let loaded = try? loader.loadBundle(at: homeDirectory)
            let resolved = loaded.map { (pipeline: $0.pipeline.spec, workers: $0.workers) }
            cachedGraph = resolved
            return resolved
        }

        let lockEntries = locks ?? []
        self.classifications = changes.map { change in
            let base = Self.classify(change, graph: graph)
            return Self.promoteIfLocked(base, locks: lockEntries)
        }
    }

    /// The highest tier across all changes, backing the later CLI exit code (contract when any
    /// contract change is present, else the max of the rest). `nil` for an empty change list.
    public var highestTier: Tier? {
        classifications.map(\.tier).max()
    }

    // MARK: - Classification

    private static func classify(_ change: ArtifactChange,
                                 graph: () -> (pipeline: PipelineSpec, workers: [String: WorkerSpec])?)
        -> ChangeClassification {
        // Anything outside the factory home cannot be classified by role — treat as unclassified local.
        guard let subpath = Layout.homeRelativeSubpath(change.path) else {
            return ChangeClassification(path: change.path, status: change.status,
                                        tier: .local, unclassified: true)
        }

        // contract — schemas/<name>.schema.yaml
        if let stem = Layout.schemaStem(fromSubpath: subpath) {
            return classifyContract(change, schemaStem: stem, graph: graph)
        }

        // refresh — conventions/* and skills/*
        if subpath.hasPrefix("\(Layout.Workspace.conventionsDir)/")
            || subpath.hasPrefix("\(Layout.Workspace.skillsDir)/") {
            return ChangeClassification(path: change.path, status: change.status, tier: .refresh)
        }

        // local — workers/*, pipeline.yaml, checks/*
        if subpath.hasPrefix("\(Layout.Workspace.workersDir)/")
            || subpath == Layout.Workspace.pipelineFile
            || subpath.hasPrefix("\(Layout.Workspace.checksDir)/") {
            return ChangeClassification(path: change.path, status: change.status, tier: .local)
        }

        // other non-runtime .ai-sdd/ path — local, unclassified
        return ChangeClassification(path: change.path, status: change.status,
                                    tier: .local, unclassified: true)
    }

    private static func classifyContract(
        _ change: ArtifactChange, schemaStem stem: String,
        graph: () -> (pipeline: PipelineSpec, workers: [String: WorkerSpec])?)
        -> ChangeClassification {
        let consumers = graph().map { Self.resolveConsumers(ofSchemaStem: stem, in: $0) } ?? []

        var flags: [ChangeFlag] = []
        var blastRadius: String? = nil
        switch change.status {
        case .deleted where !consumers.isEmpty:
            flags.append(.breakingRemoval)   // parent D2 — a removal that still has consumers
        case .added where consumers.isEmpty:
            flags.append(.nonAckBlocking)     // parent D3 — nothing depends on it yet
            blastRadius = "0 consumers (new)"
        default:
            break
        }

        return ChangeClassification(path: change.path, status: change.status, tier: .contract,
                                    consumers: consumers, flags: flags, blastRadius: blastRadius)
    }

    /// Every pipeline node whose worker `consumes` the schema identified by `stem`, as (node, worker).
    /// A `PortSpec.schema` matches when it equals the stem exactly or has the `<stem>.v<digits>` shape
    /// (the versioned id form, e.g. `feature-plan` -> `feature-plan.v1`).
    private static func resolveConsumers(
        ofSchemaStem stem: String,
        in graph: (pipeline: PipelineSpec, workers: [String: WorkerSpec])) -> [ChangeConsumer] {
        graph.pipeline.nodes.compactMap { node -> ChangeConsumer? in
            guard let workerName = node.worker,
                  let worker = graph.workers[workerName],
                  let consumes = worker.consumes,
                  consumes.contains(where: { Self.schemaId($0.schema, matchesStem: stem) }) else {
                return nil
            }
            return ChangeConsumer(node: node.id, worker: workerName)
        }
    }

    /// Whether a `PortSpec.schema` id refers to the schema file with the given filename stem.
    static func schemaId(_ schemaId: String, matchesStem stem: String) -> Bool {
        if schemaId == stem { return true }
        guard schemaId.hasPrefix("\(stem).v") else { return false }
        let version = schemaId.dropFirst(stem.count + 2)   // after "<stem>.v"
        return !version.isEmpty && version.allSatisfy(\.isNumber)
    }

    // MARK: - Lock loading & frozen promotion (ADR-0031)

    /// Load `.ai-sdd/locks.yaml` (a top-level list of `LockEntry`) via the same Yams `YAMLDecoder`
    /// the spec loader uses — no second parser. An absent file returns `[]` and no error (requirement
    /// L2); a present-but-malformed file throws the decode error (the CLI slice decides refuse/report).
    static func loadLocks(homeDirectory: URL) throws -> [LockEntry] {
        let url = Layout.locksURL(homeDirectory: homeDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let yaml = try String(contentsOf: url, encoding: .utf8)
        return try YAMLDecoder().decode([LockEntry].self, from: yaml)
    }

    /// The reason of the first lock entry (by manifest order) whose glob matches `path`, or `nil` if
    /// none match. First-match-wins makes overlapping globs deterministic.
    static func lockReason(forPath path: String, locks: [LockEntry]) -> String? {
        locks.first { Self.glob($0.glob, matches: path) }?.reason
    }

    /// Path-prefix glob matching: a glob ending in `*` matches any path sharing the literal prefix
    /// before the `*`; a glob with no `*` matches that exact path. No fnmatch/regex (ADR-0031 D-GLOB).
    static func glob(_ glob: String, matches path: String) -> Bool {
        if glob.hasSuffix("*") {
            return path.hasPrefix(String(glob.dropLast()))
        }
        return path == glob
    }

    /// If `base.path` matches a lock glob, return a copy promoted to `frozen` with `.locked` appended
    /// and `lockReason` set to the matched glob's reason; otherwise return `base` unchanged. The
    /// post-pass that layers freezing on top of base classification (ADR-0031 D-PROMOTION-COMPOSES).
    static func promoteIfLocked(_ base: ChangeClassification, locks: [LockEntry]) -> ChangeClassification {
        guard let reason = Self.lockReason(forPath: base.path, locks: locks) else { return base }
        var promoted = base
        promoted.tier = .frozen
        promoted.flags.append(.locked)
        promoted.lockReason = reason
        return promoted
    }
}
