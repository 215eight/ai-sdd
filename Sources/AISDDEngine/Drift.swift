import Foundation
import AISDDModels

/// The kind of drift a finding reports — the deterministic kinds of ADR-0033 this slice ships.
/// Kind 3 (convention↔code citation) is the next slice (`drift-conventions`) and is not modeled here.
public enum DriftKind: String, Equatable, Sendable, CaseIterable {
    /// A committed Tier-1 structural check no longer matches the template its schema reconstructs to
    /// (or is missing / orphaned). Remedy: recompile the schema's gates.
    case staleGate = "stale-gate"
    /// A committed fixture no longer validates against its current schema. Remedy: fix the fixture.
    case fixtureSchema = "fixture-schema"
}

/// One drift finding: which kind, the subject it concerns (a repo-relative path or schema name), the
/// remedy that reconciles it, and — additively (ADR-0032) — whether the subject artifact is
/// `hand-edited` per the provenance manifest. The engine is pure: it never reads the clock or disk.
public struct DriftFinding: Equatable, Sendable {
    public var kind: DriftKind
    public var subject: String
    public var detail: String
    public var remedy: String
    public var handEdited: Bool

    public init(kind: DriftKind, subject: String, detail: String, remedy: String, handEdited: Bool = false) {
        self.kind = kind
        self.subject = subject
        self.detail = detail
        self.remedy = remedy
        self.handEdited = handEdited
    }
}

/// The deterministic drift detector (ADR-0033, Kinds 1+2). A pure engine over injected inputs —
/// loaded schemas, the committed structural checks, fixture contents, and a `Provenance` manifest —
/// so it is unit-testable over temp fixtures. The CLI does the file IO at the edges (load via
/// `SpecLoader`/`Provenance.load`), calls `scan`, and maps findings to grouped stdout + an advisory
/// exit code (never a blocking throw on a clean repo — Dr2).
///
/// Kind 1 (stale gate) is scoped to the deterministically reconstructible Tier-1 structural check:
/// the compile-schema skill defines it as a FIXED MECHANICAL TEMPLATE keyed only off the schema name
/// (see D-KIND1-COMPILER-PROSE), so `Drift` rebuilds that template in pure Swift and diffs it against
/// the committed check. Tier-2/Tier-3 recompilation is LLM skill prose, not engine code, and is out
/// of scope.
public enum Drift {
    /// A schema loaded for Kind 1: its name (stem) and the format its artifact uses (`yaml` by
    /// default), which the structural-check `command` template embeds.
    public struct SchemaInput: Equatable, Sendable {
        public var name: String
        public var version: Int
        public var format: String
        public init(name: String, version: Int, format: String) {
            self.name = name
            self.version = version
            self.format = format
        }
    }

    /// A committed structural check for Kind 1: the schema name it claims to gate and the parsed spec.
    public struct CommittedCheck: Equatable, Sendable {
        public var checkName: String
        public var spec: CheckSpec
        public init(checkName: String, spec: CheckSpec) {
            self.checkName = checkName
            self.spec = spec
        }
    }

    /// A fixture↔schema pairing for Kind 2: the committed fixture's repo-relative path, its loaded
    /// contents, and the schema to validate it against.
    public struct FixtureInput: Equatable, Sendable {
        public var path: String
        public var contents: String
        public var schema: SchemaSpec
        public init(path: String, contents: String, schema: SchemaSpec) {
            self.path = path
            self.contents = contents
            self.schema = schema
        }
    }

    /// Reconstruct the FIXED Tier-1 structural-check template for a schema, purely off its name +
    /// version + format. This MUST match what `ai-sdd-compile-schema` commits so a reconciled repo
    /// yields no findings. The committed format is `swift run ai-sdd check <schema-path> <artifact-path>`.
    public static func structuralCheckName(for schema: String) -> String { "\(schema).structure" }

    /// The expected structural `CheckSpec` for a schema (name, deterministic kind, the `check` command
    /// over the schema + artifact paths, `required: true`). Pure — keyed only off the schema fields.
    public static func expectedStructuralCheck(for schema: SchemaInput) -> CheckSpec {
        let schemaPath = ".ai-sdd/schemas/\(schema.name).schema.yaml"
        let artifactPath = ".ai-sdd/artifacts/\(schema.name).v\(schema.version).\(schema.format)"
        return CheckSpec(
            checkKind: "deterministic",
            command: "swift run ai-sdd check \(schemaPath) \(artifactPath)",
            required: true)
    }

    /// Compute the deterministic drift findings, grouped/ordered by kind (stale-gate then
    /// fixture-schema), each finding deterministically ordered within its kind.
    ///
    /// - `schemas`: every `schemas/*.schema.yaml` loaded (for Kind 1's reconstruction).
    /// - `committedChecks`: every committed `checks/*.structure.check.yaml` loaded (parsed CheckSpec
    ///   keyed by its schema name). A schema with no committed structural check, or a committed
    ///   structural check with no schema, is itself a finding.
    /// - `fixtures`: the fixed fixture↔schema map (Kind 2).
    /// - `provenance`: the loaded manifest; a subject path classifying as `.handEdited` against its
    ///   on-disk bytes (supplied via `handEditedPaths`) carries the annotation.
    /// - `handEditedPaths`: the set of repo-relative subject paths the CLI has classified as
    ///   `hand-edited` (the CLI does the disk read; the engine stays pure over the resolved set).
    public static func scan(
        schemas: [SchemaInput],
        committedChecks: [CommittedCheck],
        fixtures: [FixtureInput],
        handEditedPaths: Set<String> = []
    ) throws -> [DriftFinding] {
        var findings: [DriftFinding] = []
        findings.append(contentsOf: staleGateFindings(
            schemas: schemas, committedChecks: committedChecks, handEditedPaths: handEditedPaths))
        findings.append(contentsOf: try fixtureFindings(
            fixtures: fixtures, handEditedPaths: handEditedPaths))
        return findings
    }

    // MARK: - Kind 1: stale structural gate

    private static func staleGateFindings(
        schemas: [SchemaInput],
        committedChecks: [Drift.CommittedCheck],
        handEditedPaths: Set<String>
    ) -> [DriftFinding] {
        let committedBySchema = Dictionary(
            committedChecks.map { ($0.checkName, $0.spec) }, uniquingKeysWith: { first, _ in first })
        var findings: [DriftFinding] = []

        for schema in schemas.sorted(by: { $0.name < $1.name }) {
            let checkName = structuralCheckName(for: schema.name)
            let committedPath = ".ai-sdd/checks/\(checkName).check.yaml"
            let handEdited = handEditedPaths.contains(committedPath)
            let expected = expectedStructuralCheck(for: schema)

            guard let actual = committedBySchema[checkName] else {
                findings.append(.init(
                    kind: .staleGate, subject: schema.name,
                    detail: "missing structural check \(committedPath)",
                    remedy: "recompile \(schema.name)", handEdited: handEdited))
                continue
            }
            if actual != expected {
                findings.append(.init(
                    kind: .staleGate, subject: schema.name,
                    detail: "committed \(committedPath) does not match the reconstructed Tier-1 template",
                    remedy: "recompile \(schema.name)", handEdited: handEdited))
            }
        }

        // An orphaned structural check (a committed `<name>.structure` whose schema is gone).
        let schemaNames = Set(schemas.map { structuralCheckName(for: $0.name) })
        for committed in committedChecks.sorted(by: { $0.checkName < $1.checkName })
        where !schemaNames.contains(committed.checkName) {
            let stem = committed.checkName.hasSuffix(".structure")
                ? String(committed.checkName.dropLast(".structure".count))
                : committed.checkName
            let committedPath = ".ai-sdd/checks/\(committed.checkName).check.yaml"
            findings.append(.init(
                kind: .staleGate, subject: stem,
                detail: "committed \(committedPath) has no matching schema",
                remedy: "recompile \(stem)",
                handEdited: handEditedPaths.contains(committedPath)))
        }
        return findings
    }

    // MARK: - Kind 2: fixture ↔ schema

    private static func fixtureFindings(
        fixtures: [Drift.FixtureInput],
        handEditedPaths: Set<String>
    ) throws -> [DriftFinding] {
        var findings: [DriftFinding] = []
        for fixture in fixtures.sorted(by: { $0.path < $1.path }) {
            let violations = try SchemaValidator.validate(fixture.schema, artifactYAML: fixture.contents)
            guard !violations.isEmpty else { continue }
            let detail = violations.map { "\($0.field): \($0.message)" }.joined(separator: "; ")
            findings.append(.init(
                kind: .fixtureSchema, subject: fixture.path,
                detail: detail, remedy: "fix fixture \(fixture.path)",
                handEdited: handEditedPaths.contains(fixture.path)))
        }
        return findings
    }
}
