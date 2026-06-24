import Foundation

/// Static metadata for a Run (which pipeline it executes).
public struct RunMeta: Codable, Equatable, Sendable {
    public var runId: String
    public var pipelineDir: String

    public init(runId: String, pipelineDir: String) {
        self.runId = runId
        self.pipelineDir = pipelineDir
    }
}

/// A local, file-based run store: per-run metadata + an **append-only** event log (one file per
/// event). `RunState` is always a projection of the log via the `Reducer` (architecture.md §6).
/// Paths come from `RunLayout`, so no filename is hard-coded here.
///
/// Single-user/local MVP. The shared Git-backed store (ADR-0025) will implement the same
/// one-file-per-event shape later, so nothing here has to change to go multi-user.
public struct RunStore: Sendable {
    public let root: URL

    /// Capture the live git identity (`user.name` + `user.email`) as the append-time owner.
    /// Injectable `@Sendable` closure mirroring `ArtifactDiff.git` / `CheckRunner.shell` so tests
    /// need no real git config; resolves to `.unowned` when neither name nor email is present
    /// (decision `owner-via-injectable-git-closure`).
    public var captureOwner: @Sendable () -> RunEventOwner

    /// Resolve the current git toplevel (`git rev-parse --show-toplevel`) as an absolute path, or
    /// `nil` when there is no repo. Injectable `@Sendable` closure mirroring `captureOwner` /
    /// `ArtifactDiff.git`, so the relative-conversion and legacy-heal path logic is unit-testable
    /// without a real repo (decision `injectable-git-toplevel-closure`). A `nil` toplevel makes the
    /// pure helpers no-ops — the stored form is preserved exactly.
    public var gitToplevel: @Sendable () -> String?

    public init(root: URL,
                captureOwner: @escaping @Sendable () -> RunEventOwner = RunStore.gitIdentity,
                gitToplevel: @escaping @Sendable () -> String? = RunStore.gitToplevel) {
        self.root = root
        self.captureOwner = captureOwner
        self.gitToplevel = gitToplevel
    }

    /// The conventional local store at `<base>/.ai-sdd/runs`.
    public static func local(under base: URL) -> RunStore {
        RunStore(root: base
            .appendingPathComponent(Layout.homeDir, isDirectory: true)
            .appendingPathComponent(Layout.runsDir, isDirectory: true))
    }

    /// The base directory this store hangs off of — the exact inverse of `local(under:)`, which builds
    /// `root = <base>/Layout.homeDir/Layout.runsDir`. Dropping the two trailing path components
    /// (`runs`, then `.ai-sdd`) recovers the base structurally, reusing the same `Layout` literals
    /// `local(under:)` appends. Only meaningful for stores constructed via `local(under:)` (or an
    /// equivalent `<base>/.ai-sdd/runs` root).
    public var base: URL { root.deletingLastPathComponent().deletingLastPathComponent() }

    /// The `<base>` to pass to `local(under:)` so a store resolves against the `.ai-sdd` home that
    /// GOVERNS `target` — the target-relative complement to `local(under:)` (forward) and `base`
    /// (inverse). Standardizes `target` to an absolute URL (so relative and absolute targets behave
    /// identically, and `.`/`..`/trailing-slash collapse), then ascends via
    /// `deletingLastPathComponent()` to the CLOSEST (nearest-the-leaf) component equal to
    /// `Layout.homeDir` that is the target or an ancestor of it, and returns that component's parent.
    /// If the target has no `.ai-sdd` component, falls back to the current working directory —
    /// preserving today's cwd-rooted store. Reuses the internal `Layout.homeDir` literal directly
    /// (same module) so no path string is duplicated.
    public static func base(forTarget target: URL) -> URL {
        var current = target.standardizedFileURL
        while current.pathComponents.count > 1 {
            if current.lastPathComponent == Layout.homeDir {
                return current.deletingLastPathComponent()
            }
            current = current.deletingLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    }

    public func exists(_ runId: String) -> Bool {
        FileManager.default.fileExists(atPath: layout(runId).meta.path)
    }

    /// Create a run, persisting `pipelineDir` as a path RELATIVE to the current git toplevel when it
    /// is absolute and lives under that toplevel (decision `relative-conversion-in-runstore`). A
    /// path that is already relative, that is not under the toplevel, or any input when there is no
    /// toplevel, is stored byte-for-byte as given — keeping today's behavior outside a repo and for
    /// out-of-tree pipelines.
    public func create(runId: String, pipelineDir: String) throws {
        let layout = layout(runId)
        try FileManager.default.createDirectory(at: layout.eventsDir, withIntermediateDirectories: true)
        let stored = Self.relativize(pipelineDir, toplevel: gitToplevel())
        try write(RunMeta(runId: runId, pipelineDir: stored), to: layout.meta)
    }

    /// Read a run's metadata, HEALING a legacy absolute `pipelineDir` that no longer resolves on
    /// disk: strip its prefix up to the trailing `.ai-sdd/` segment, re-anchor against the current
    /// toplevel, and — only if that re-anchored path resolves — return the migrated (relative) form
    /// (decision `heal-only-what-resolves`). The heal is side-effect-free here: nothing is rewritten
    /// on read (no new mtime); `append` persists the canonical form on the next mutation. An absolute
    /// path that still resolves, a path that resolves nowhere, and an already-relative path are all
    /// returned unchanged.
    public func meta(of runId: String) throws -> RunMeta {
        var meta = try JSONDecoder().decode(RunMeta.self, from: Data(contentsOf: layout(runId).meta))
        meta.pipelineDir = Self.heal(meta.pipelineDir,
                                     toplevel: gitToplevel(),
                                     exists: { FileManager.default.fileExists(atPath: $0) })
        return meta
    }

    /// Append an event — never rewrites an existing file (append-only). The event is wrapped in a
    /// `RunEventRecord` carrying an `at` stamped from the INJECTED `now` (defaulted only here, at
    /// the call boundary — the pure path never reads the wall clock, decision
    /// `inject-now-at-append-boundary`) normalized to UTC `…Z`, and an `owner` captured from the
    /// injectable git-identity closure.
    public func append(_ event: RunEvent, to runId: String,
                       now: Date = Date(), owner: RunEventOwner? = nil) throws {
        let next = (try? eventFiles(runId).count) ?? 0
        let record = RunEventRecord(event: event,
                                    at: RunStore.utcZ(now),
                                    owner: owner ?? captureOwner())
        try write(record, to: layout(runId).eventFile(next + 1))
        try migratePipelineDirIfNeeded(runId)
    }

    /// On the next mutation (append), persist a healed legacy `pipelineDir` as its canonical form —
    /// but ONLY when the stored form differs from what `heal` would return (decision
    /// `append-is-migration-trigger`). When the stored form already equals the canonical form the
    /// rewrite is skipped, so re-reading or re-appending a healed run.json is a no-op (idempotent).
    /// A run.json that resolves nowhere yields a canonical form equal to the stored value, so it is
    /// likewise never rewritten — left untouched for S4 to surface.
    private func migratePipelineDirIfNeeded(_ runId: String) throws {
        let metaURL = layout(runId).meta
        guard let raw = try? JSONDecoder().decode(RunMeta.self, from: Data(contentsOf: metaURL))
        else { return }
        let canonical = Self.heal(raw.pipelineDir,
                                  toplevel: gitToplevel(),
                                  exists: { FileManager.default.fileExists(atPath: $0) })
        guard canonical != raw.pipelineDir else { return }
        var migrated = raw
        migrated.pipelineDir = canonical
        try write(migrated, to: metaURL)
    }

    /// The pure event projection — decodes each persisted file tolerantly (record shape first, bare
    /// legacy `RunEvent` as fallback) and returns ONLY the `RunEvent`, so `events`/`state` and the
    /// Reducer stay metadata-free and replayable (decision `optional-fields-for-backcompat`).
    public func events(of runId: String) throws -> [RunEvent] {
        try eventFiles(runId).map { try Self.decodeRecord(Data(contentsOf: $0)).event }
    }

    /// The persisted records with their append-time metadata (`at`/`owner`) — the surface Part B's
    /// temporal metrics read (decision `surface-metadata-for-partb`). A missing `at`/`owner`
    /// (legacy bare event) is `nil` ⇒ unknown, never zero-substituted. Decodes tolerantly so old
    /// runs load without error.
    public func eventsWithMetadata(of runId: String) throws -> [RunEventRecord] {
        try eventFiles(runId).map { try Self.decodeRecord(Data(contentsOf: $0)) }
    }

    /// The current state — a pure fold of the event log.
    public func state(of runId: String) throws -> RunState {
        Reducer.reduce(RunState(), events: try events(of: runId))
    }

    public func runIds() throws -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { $0.lastPathComponent }
            .sorted()
    }

    // MARK: - Private

    private func layout(_ runId: String) -> RunLayout { RunLayout(root: root, runId: runId) }

    /// Event files in chronological order (zero-padded names sort lexically == chronologically).
    private func eventFiles(_ runId: String) throws -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: layout(runId).eventsDir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == Layout.Run.eventExtension }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    /// Decode one persisted event file tolerantly: try the `RunEventRecord` wrapper first; if that
    /// fails (a legacy file holding a bare `RunEvent`), decode the bare event and wrap it with no
    /// metadata. Lets old runs load without error and degrade (`at`/`owner` absent) rather than
    /// crashing — decision `optional-fields-for-backcompat`.
    static func decodeRecord(_ data: Data) throws -> RunEventRecord {
        let decoder = JSONDecoder()
        if let record = try? decoder.decode(RunEventRecord.self, from: data) {
            return record
        }
        return RunEventRecord(event: try decoder.decode(RunEvent.self, from: data))
    }

    /// Render a `Date` as an RFC 3339 UTC instant with a `Z` suffix via a fixed, zone-pinned
    /// ISO-8601 formatter, so events stamped in different source zones are stored canonically and
    /// totally ordered when compared as strings (decision `utc-z-canonical-storage`).
    static func utcZ(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// The default owner capture: read `git config user.name` / `user.email` via `Process` (the
    /// same `/usr/bin/env git` invocation `ArtifactDiff.git` uses). Resolves to `.unowned` when
    /// neither name nor email is available — an honest gap, not a guess.
    public static let gitIdentity: @Sendable () -> RunEventOwner = {
        func config(_ key: String) -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git", "config", key]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            guard (try? process.run()) != nil else { return "" }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let name = config("user.name")
        let email = config("user.email")
        if name.isEmpty && email.isEmpty { return .unowned }
        return .identified(name: name, email: email)
    }

    /// The default git-toplevel lookup: `git rev-parse --show-toplevel` via `Process` (the same
    /// `/usr/bin/env git` invocation `gitIdentity` / `ArtifactDiff.git` use). Returns the absolute
    /// toplevel path, or `nil` when the command fails or produces no output (not in a repo) — an
    /// honest absence that makes the path helpers no-ops rather than guessing a root.
    public static let gitToplevel: @Sendable () -> String? = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "rev-parse", "--show-toplevel"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let top = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return top.isEmpty ? nil : top
    }

    // MARK: - Pure path helpers (I/O-free, decision `pure-path-migration-helper`)

    /// Convert an absolute `pipelineDir` that lives under `toplevel` into a `toplevel`-relative path
    /// (e.g. `.ai-sdd/features/run-integrity`). Returns the input unchanged when it is already
    /// relative, when `toplevel` is `nil`, or when the path is not actually under `toplevel`. Pure:
    /// no filesystem or git access — `toplevel` is supplied by the caller.
    static func relativize(_ pipelineDir: String, toplevel: String?) -> String {
        guard (pipelineDir as NSString).isAbsolutePath, let toplevel else { return pipelineDir }
        let topComponents = standardizedComponents(toplevel)
        let pathComponents = standardizedComponents(pipelineDir)
        guard pathComponents.count >= topComponents.count,
              Array(pathComponents.prefix(topComponents.count)) == topComponents else {
            return pipelineDir
        }
        let tail = pathComponents.dropFirst(topComponents.count)
        return tail.isEmpty ? "." : tail.joined(separator: "/")
    }

    /// Compute the canonical stored form of a `pipelineDir` given the current `toplevel` and an
    /// `exists` predicate (the only injected I/O). The rules, in order:
    ///   1. A relative stored path is returned unchanged (already canonical / resolved by the reader).
    ///   2. An absolute path that still resolves under `toplevel` is relativized.
    ///   3. An absolute path that no longer resolves is HEALED — its prefix is stripped up to the
    ///      trailing `.ai-sdd/` segment, re-anchored against `toplevel`; if that re-anchored path
    ///      `exists`, the relative (migrated) form is returned.
    ///   4. Anything that still resolves nowhere (no `.ai-sdd/` segment, or the re-anchored path is
    ///      absent) is returned BYTE-FOR-BYTE unchanged, deferring it to S4.
    /// Pure: the wall clock, git, and the filesystem stay at the store edge; `toplevel` and `exists`
    /// are inputs, so the same logic is exercised in tests with no real repo.
    static func heal(_ stored: String, toplevel: String?, exists: (String) -> Bool) -> String {
        guard (stored as NSString).isAbsolutePath, let toplevel else { return stored }

        // (2) Still resolves where stored ⇒ just standardize to the relative form.
        if exists(stored) { return relativize(stored, toplevel: toplevel) }

        // (3) Strip up to the trailing `.ai-sdd/` segment and re-anchor under the current toplevel.
        let components = standardizedComponents(stored)
        guard let homeIndex = components.lastIndex(of: Layout.homeDir) else { return stored }
        let tail = components[homeIndex...]
        let candidate = ([toplevel] + tail).joined(separator: "/")
        guard exists(candidate) else { return stored }     // (4) heal only what resolves
        return tail.joined(separator: "/")
    }

    /// Path components of a standardized (`.`/`..`/trailing-slash collapsed) absolute path, with the
    /// leading `/` root dropped so two absolute paths compare by their meaningful segments.
    private static func standardizedComponents(_ path: String) -> [String] {
        URL(fileURLWithPath: path).standardizedFileURL.pathComponents.filter { $0 != "/" }
    }
}
