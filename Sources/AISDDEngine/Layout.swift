import Foundation

/// The tool's on-disk names, defined in exactly one place so no path literal is repeated.
/// The `*Layout` structs below turn these into concrete `URL`s.
enum Layout {
    static let homeDir = ".ai-sdd"
    static let runsDir = "runs"
    static let artifactsDir = "artifacts"

    /// The factory home as a git pathspec — scopes `git diff` to `.ai-sdd/`.
    static let homePathspec = "\(homeDir)/"

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
    }
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
