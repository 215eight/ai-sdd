import Foundation

/// The factory's on-disk names, defined in exactly one place so no path literal is repeated.
/// The `*Layout` structs below turn these into concrete `URL`s.
enum Layout {
    static let factoryDir = ".factory"
    static let runsDir = "runs"

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

/// Type-safe paths for a pipeline workspace directory: `<dir>/pipeline.yaml`, `<dir>/workers/…`
struct WorkspaceLayout {
    let dir: URL

    var pipeline: URL { dir.appendingPathComponent(Layout.Workspace.pipelineFile) }
    var workers: URL { dir.appendingPathComponent(Layout.Workspace.workersDir, isDirectory: true) }
}
