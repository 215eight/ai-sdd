import Foundation

/// The tool's on-disk names, defined in exactly one place so no path literal is repeated.
/// The `*Layout` structs below turn these into concrete `URL`s. The enum is `public` so the CLI can
/// share centralized path literals (per the conventions); members stay internal unless marked `public`.
public enum Layout {
    static let homeDir = ".ai-sdd"
    static let runsDir = "runs"
    static let artifactsDir = "artifacts"
    /// The on-disk programs directory name (`.ai-sdd/programs`) — one program workspace per subdir,
    /// each with its own master `pipeline.yaml`. `public` so the downstream CLI slice can compose a
    /// concrete program dir from it without an inline path literal (the conventions mandate path
    /// literals live here, never inline).
    public static let programsDir = "programs"
    /// The hand-edited committed lock manifest (`.ai-sdd/locks.yaml`) — a top-level list of
    /// `{ glob, reason }` entries the `frozen` tier promotion reads (ADR-0031). Absent ⇒ no locks.
    static let locksFile = "locks.yaml"

    /// The committed provenance manifest (`.ai-sdd/provenance.json`) — a path-keyed map of
    /// `{ generator, generatedAt, contentHash }` the `Provenance` engine reads/writes (ADR-0032).
    /// Absent ⇒ empty manifest.
    static let provenanceFile = "provenance.json"

    /// The factory home as a git pathspec — scopes `git diff` to `.ai-sdd/`.
    static let homePathspec = "\(homeDir)/"

    /// The framework skills source (`.ai-sdd/skills`). `ai-sdd surface` symlinks each framework
    /// skill here into every coding agent's native skill dir.
    static let skillsSource = "\(homeDir)/\(Workspace.skillsDir)"

    /// The prefix marking a *framework* skill (`ai-sdd-bootstrap`, `ai-sdd-plan`, …). Worker skills
    /// (`plan-feature`/`implement-feature`/`review-feature`) lack it and resolve by path, never surfaced.
    static let frameworkSkillPrefix = "ai-sdd-"

    /// The marker file every surfaceable skill must contain.
    static let skillManifestFile = "SKILL.md"

    // MARK: - Embedded-framework resource literals (EmbeddedFramework / Bundle.module)
    //
    // The binary embeds the framework skills + the `pre-commit` integrity-hook source as SwiftPM
    // resources of the `AISDDEngine` target (copied via symlinks under `Sources/AISDDEngine/Resources/`
    // that point at the repo-root `skills/`/`hooks/` source of truth). These are the names the
    // resources land under inside `Bundle.module`, kept here so `EmbeddedFramework` and its tests
    // never inline a path string (the conventions mandate path names live in `Layout.swift`).

    /// The bundled resource directory holding every embedded skill (`<skill>/SKILL.md`), as it appears
    /// in `Bundle.module`. Matches the `.copy("Resources/skills")` basename in `Package.swift`.
    public static let embeddedSkillsResourceDir = "skills"

    /// The bundled resource directory holding the integrity-hook source, as it appears in
    /// `Bundle.module`. Matches the `.copy("Resources/hooks")` basename in `Package.swift`.
    public static let embeddedHookResourceDir = "hooks"

    /// The integrity-hook file name within the embedded `hooks` resource dir (`hooks/pre-commit`).
    public static let embeddedHookFile = "pre-commit"

    /// The canonical framework skills embedded by this slice, sorted. The runtime accessor derives the
    /// live set from the bundle (so it self-updates when a later slice adds a skill); this list is the
    /// expected-id baseline the tests assert against. `ai-sdd-update` is added by a later slice.
    public static let embeddedFrameworkSkillIds = [
        "ai-sdd-bootstrap",
        "ai-sdd-cheatsheet",
        "ai-sdd-compile-schema",
        "ai-sdd-plan",
        "ai-sdd-plan-program",
        "ai-sdd-run"
    ]

    /// The agent→native-skill-dir table — the *one* declarative place this mapping lives. Adding a
    /// coding agent is a one-line edit here. Each dir is two levels below the repo root, so every
    /// surfaced symlink shares the same relative target (`skillSurfaceTarget`).
    static let agentSkillSurfaces: [(agent: String, dir: String)] = [
        (agent: "codex", dir: ".agents/skills"),
        (agent: "claude", dir: ".claude/skills")
    ]

    /// The relative symlink target for a surfaced skill, from inside an agent dir (two levels below
    /// the repo root) back to `.ai-sdd/skills/<name>`. The `../../` matches every agent dir's depth.
    static func skillSurfaceTarget(_ name: String) -> String {
        "../../\(skillsSource)/\(name)"
    }

    /// The gitignored runtime subdirs under the home, as repo-relative path prefixes. Derived from
    /// the names above so no path literal is repeated. `changedArtifacts` drops anything under these.
    static let runtimeExcludedPrefixes = [
        "\(homeDir)/\(runsDir)/",
        "\(homeDir)/\(artifactsDir)/"
    ]

    /// Whether a repo-relative path lives under a runtime-excluded prefix and must be dropped.
    static func isExcludedArtifactPath(_ path: String) -> Bool {
        runtimeExcludedPrefixes.contains { path.hasPrefix($0) }
    }

    /// Names within a single run directory.
    enum Run {
        static let metaFile = "run.json"
        static let eventsDir = "events"
        static let eventExtension = "json"
        static func eventFile(_ sequence: Int) -> String {
            "\(String(format: "%06d", sequence)).\(eventExtension)"
        }
    }

    /// Names within a pipeline workspace directory.
    enum Workspace {
        static let pipelineFile = "pipeline.yaml"
        static let workersDir = "workers"
        static let workerExtension = "yaml"
        static let checksDir = "checks"
        static let checkExtension = "yaml"
        static let schemasDir = "schemas"
        static let conventionsDir = "conventions"
        static let skillsDir = "skills"
        /// A schema file is `<name>.schema.yaml` — the double extension that marks the contract tier.
        static let schemaSuffix = ".schema.yaml"
        /// A check file is `<name>.check.yaml` — the suffix `ai-sdd check` / drift / compile read.
        static let checkSuffix = ".check.yaml"
    }

    /// The repo-relative subpath of an artifact under `.ai-sdd/` (drops the `.ai-sdd/` prefix), used
    /// by `ChangePlan` to classify a changed path by its role. Returns nil for a path that is not
    /// under the factory home.
    static func homeRelativeSubpath(_ repoRelativePath: String) -> String? {
        guard repoRelativePath.hasPrefix(homePathspec) else { return nil }
        return String(repoRelativePath.dropFirst(homePathspec.count))
    }

    /// The lock manifest file inside a factory home dir (`<home>/locks.yaml`). `homeDirectory` is the
    /// same `.ai-sdd/` workspace dir `ChangePlan.init` already takes for bundle loading.
    static func locksURL(homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent(locksFile)
    }

    /// The provenance manifest file inside a factory home dir (`<home>/provenance.json`). Mirrors
    /// `locksURL(homeDirectory:)`; `homeDirectory` is the same `.ai-sdd/` workspace dir.
    static func provenanceURL(homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent(provenanceFile)
    }

    /// The schema id carried in a `PortSpec.schema` for a changed `schemas/<name>.schema.yaml` path.
    /// The on-disk file is `<name>.schema.yaml` (stem `<name>`); the id used in worker `consumes`
    /// adds the version segment (`<name>.v<N>`, e.g. `feature-plan` -> `feature-plan.v1`). Since the
    /// changed file (especially a deleted one) may be gone, the classifier matches a `PortSpec.schema`
    /// that is either exactly `<name>` or has the `<name>.v<digits>` shape — see `ChangePlan`.
    static func schemaStem(fromSubpath subpath: String) -> String? {
        guard subpath.hasPrefix("\(Workspace.schemasDir)/"),
              subpath.hasSuffix(Workspace.schemaSuffix) else { return nil }
        let withoutDir = String(subpath.dropFirst(Workspace.schemasDir.count + 1))
        return String(withoutDir.dropLast(Workspace.schemaSuffix.count))
    }

    // MARK: - Compiled-check path literals (SchemaCompiler)
    //
    // The repo-relative paths the Tier-1 structural-check template embeds. Centralized here (one
    // place per literal) so `SchemaCompiler` stays free of inline path strings (A7). These MUST
    // match the committed reality the compiler reproduces: `Drift.expectedStructuralCheck` builds
    // the same strings inline today; the downstream `dedupe-drift` slice folds it onto these.

    /// The repo-relative source path of a schema spec: `.ai-sdd/schemas/<name>.schema.yaml`.
    static func schemaSourcePath(name: String) -> String {
        "\(homeDir)/\(Workspace.schemasDir)/\(name)\(Workspace.schemaSuffix)"
    }

    /// The repo-relative path of a schema's produced artifact (interim convention):
    /// `.ai-sdd/artifacts/<name>.v<version>.<format>`.
    static func artifactPath(name: String, version: Int, format: String) -> String {
        "\(homeDir)/\(artifactsDir)/\(name).v\(version).\(format)"
    }

    /// The name of a schema's Tier-1 structural check: `<name>.structure`.
    static func structuralCheckName(name: String) -> String { "\(name).structure" }

    /// The repo-relative source path of a committed check: `.ai-sdd/checks/<checkName>.check.yaml`.
    static func checkSourcePath(checkName: String) -> String {
        "\(homeDir)/\(Workspace.checksDir)/\(checkName)\(Workspace.checkSuffix)"
    }

    /// The conventions subdir name (`conventions`), re-exported `public` for the CLI's directory glob.
    public static let conventionsSubdir = Workspace.conventionsDir

    /// The repo-relative conventions dir: `.ai-sdd/conventions`. The CLI globs `*.md` here for the
    /// per-stack Discovery Records drift's Kind 3 re-checks.
    public static let conventionsDirPath = "\(homeDir)/\(Workspace.conventionsDir)"

    /// A convention file's markdown extension. A convention is `.ai-sdd/conventions/<stack>.md`, whose
    /// stem (`<stack>`) is the stack name carried in a Kind-3 finding's `re-bootstrap <stack>` remedy.
    public static let conventionExtension = "md"

    /// The repo-relative path of a stack's convention file: `.ai-sdd/conventions/<stack>.md`.
    public static func conventionSourcePath(stack: String) -> String {
        "\(conventionsDirPath)/\(stack).\(conventionExtension)"
    }

    // MARK: - Seed target-side path literals (Seeder)
    //
    // The concrete files `ai-sdd seed [TARGET]` reconciles in an adopting repo. Centralized here (one
    // place per literal, per the conventions) so `Seeder` never inlines a path string. All are
    // resolved under the seed TARGET (default: cwd) — never the running binary's own repo.

    /// The version stamp inside a target's factory home (`.ai-sdd/VERSION`). Seed writes the running
    /// binary's version string here verbatim; downstream update-check slices read it.
    public static let versionStampFile = "VERSION"

    /// The repo-relative VERSION stamp path: `.ai-sdd/VERSION`.
    public static let versionStampPath = "\(homeDir)/\(versionStampFile)"

    /// The materialized integrity-hook source under a target's home (`.ai-sdd/hooks/pre-commit`) —
    /// `EmbeddedFramework.materialize(to:)` writes it; seed installs the `.git` hook from it.
    public static let homeHookPath = "\(homeDir)/\(embeddedHookResourceDir)/\(embeddedHookFile)"

    /// The git hooks directory inside a target (`.git/hooks`).
    public static let gitHooksDir = ".git/hooks"

    /// The git dir whose presence gates the hook-install step (`.git`).
    public static let gitDir = ".git"

    /// The installed pre-commit hook path inside a target (`.git/hooks/pre-commit`).
    public static let gitPreCommitHook = "\(gitHooksDir)/\(embeddedHookFile)"

    /// The chained-foreign-hook path (`.git/hooks/.pre-commit.local`) — a non-managed pre-commit hook
    /// is moved here exactly once so the managed hook can take its place without losing it.
    public static let gitChainedHook = "\(gitHooksDir)/.\(embeddedHookFile).local"

    /// The marker every managed hook carries; its presence in an installed `.git/hooks/pre-commit`
    /// means "refresh in place" (vs. a foreign hook, which is chained once). Matches `bootstrap.sh`.
    public static let managedHookMarker = "ai-sdd:managed-hook"

    /// The Claude agent session-hook config a seed merges into (`.claude/settings.json`).
    public static let claudeSettingsPath = ".claude/settings.json"

    /// The Codex agent session-hook config a seed merges into (`.codex/hooks.json`).
    public static let codexHooksPath = ".codex/hooks.json"

    /// The hooks-object key under which SessionStart entries live in both agent configs.
    public static let sessionStartKey = "SessionStart"

    /// The top-level `hooks` object key in both agent configs.
    public static let hooksKey = "hooks"

    /// The Codex SessionStart matcher (Claude's entry needs none).
    public static let codexSessionMatcher = "startup|resume"

    /// The literal command string a seeded SessionStart hook runs — seed installs only the STRING;
    /// the `ai-sdd update --check` command itself is a later slice.
    public static let updateCheckCommand = "ai-sdd update --check"
}

/// Type-safe paths for one Run inside a store root: `<root>/<runId>/…`
struct RunLayout {
    let root: URL
    let runId: String

    var dir: URL { root.appendingPathComponent(runId, isDirectory: true) }
    var meta: URL { dir.appendingPathComponent(Layout.Run.metaFile) }
    var eventsDir: URL { dir.appendingPathComponent(Layout.Run.eventsDir, isDirectory: true) }
    func eventFile(_ sequence: Int) -> URL {
        eventsDir.appendingPathComponent(Layout.Run.eventFile(sequence))
    }
}

/// Where produced artifacts live under a workspace (interim convention, see ai-sdd-compile-schema):
/// `<workspace>/.ai-sdd/artifacts/<schema>.<ext>`. The gates read from here; the engine reads a
/// failed verdict artifact from here to route rework (§9).
public struct ArtifactLayout {
    public let workspace: URL
    public init(workspace: URL) { self.workspace = workspace }

    public var dir: URL {
        workspace.appendingPathComponent(Layout.homeDir, isDirectory: true)
            .appendingPathComponent(Layout.artifactsDir, isDirectory: true)
    }
    public func file(schema: String, ext: String) -> URL {
        dir.appendingPathComponent("\(schema).\(ext)")
    }
}

/// Type-safe paths for a pipeline workspace directory: `<dir>/pipeline.yaml`, `<dir>/workers/…`
struct WorkspaceLayout {
    let dir: URL

    var pipeline: URL { dir.appendingPathComponent(Layout.Workspace.pipelineFile) }
    var workers: URL { dir.appendingPathComponent(Layout.Workspace.workersDir, isDirectory: true) }
    var checks: URL { dir.appendingPathComponent(Layout.Workspace.checksDir, isDirectory: true) }
}
