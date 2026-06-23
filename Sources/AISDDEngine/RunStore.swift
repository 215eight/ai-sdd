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

    public init(root: URL) { self.root = root }

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

    public func create(runId: String, pipelineDir: String) throws {
        let layout = layout(runId)
        try FileManager.default.createDirectory(at: layout.eventsDir, withIntermediateDirectories: true)
        try write(RunMeta(runId: runId, pipelineDir: pipelineDir), to: layout.meta)
    }

    public func meta(of runId: String) throws -> RunMeta {
        try JSONDecoder().decode(RunMeta.self, from: Data(contentsOf: layout(runId).meta))
    }

    /// Append an event — never rewrites an existing file (append-only).
    public func append(_ event: RunEvent, to runId: String) throws {
        let next = (try? eventFiles(runId).count) ?? 0
        try write(event, to: layout(runId).eventFile(next + 1))
    }

    public func events(of runId: String) throws -> [RunEvent] {
        try eventFiles(runId).map { try JSONDecoder().decode(RunEvent.self, from: Data(contentsOf: $0)) }
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
}
