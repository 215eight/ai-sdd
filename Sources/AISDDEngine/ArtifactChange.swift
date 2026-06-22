import Foundation

/// One factory artifact file changed under `.ai-sdd/` between a baseline ref and the working tree.
/// Transient runtime data consumed by the later ChangePlan classifier — deliberately not an
/// `AISDDModels` spec type (consistent with the parent feature's D5).
public struct ArtifactChange: Equatable, Sendable {
    public enum Status: String, Equatable, Sendable {
        case added       // git --name-status `A`
        case modified    // git --name-status `M`
        case deleted     // git --name-status `D`
    }

    public var path: String     // repo-relative, as git emits it
    public var status: Status

    public init(path: String, status: Status) {
        self.path = path
        self.status = status
    }
}

/// Lists the factory artifact files changed under `.ai-sdd/` between a baseline ref and the working
/// tree. It shells out to `git diff --name-status <baseline> -- .ai-sdd/` through an injectable
/// executor (mirroring `CheckRunner.execute`/`shell`), parses the name-status lines, and drops the
/// gitignored runtime subdirs (`.ai-sdd/runs/`, `.ai-sdd/artifacts/`). Read-only: it writes and
/// stages nothing.
public struct ArtifactDiff: Sendable {
    public let workingDirectory: URL
    /// Injectable command execution so tests need no real repo. Takes the git argument *vector*
    /// (not a joined string) so tests can assert the exact args passed. Returns (exitCode, stdout).
    public var execute: @Sendable (_ arguments: [String], _ cwd: URL) -> (Int32, String)

    public init(workingDirectory: URL,
                execute: @escaping @Sendable (_ arguments: [String], _ cwd: URL) -> (Int32, String) = ArtifactDiff.git) {
        self.workingDirectory = workingDirectory
        self.execute = execute
    }

    /// The changed `.ai-sdd/` artifact files relative to `baseline` (default `HEAD`), excluding the
    /// runtime-excluded prefixes. The `baseline` parameter is the future CLI `--since` value.
    public func changedArtifacts(baseline: String = "HEAD") -> [ArtifactChange] {
        let arguments = ["diff", "--name-status", baseline, "--", Layout.homePathspec]
        let (_, output) = execute(arguments, workingDirectory)
        return Self.parse(nameStatus: output)
    }

    /// Parse `git diff --name-status` output: each line is `<code>TAB<path>`. Map A/M/D to the
    /// statuses; skip R/C/T (out of scope) and blank lines; drop the runtime-excluded prefixes.
    static func parse(nameStatus output: String) -> [ArtifactChange] {
        output.split(separator: "\n", omittingEmptySubsequences: false).compactMap { rawLine -> ArtifactChange? in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            let parts = line.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 2, let code = parts.first?.first else { return nil }
            let path = parts[1]
            // Scope to the factory home (the pathspec scopes git itself; this also defends against
            // any non-home path) and drop the gitignored runtime subdirs.
            guard !path.isEmpty,
                  path.hasPrefix(Layout.homePathspec),
                  !Layout.isExcludedArtifactPath(path) else { return nil }
            switch code {
            case "A": return ArtifactChange(path: path, status: .added)
            case "M": return ArtifactChange(path: path, status: .modified)
            case "D": return ArtifactChange(path: path, status: .deleted)
            default:  return nil   // R / C / T (rename/copy/typechange) — out of scope, skip
            }
        }
    }

    /// The default executor: run `git <arguments>` in `cwd` via `Process`, capturing stdout.
    public static let git: @Sendable (_ arguments: [String], _ cwd: URL) -> (Int32, String) = { arguments, cwd in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = cwd
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return (127, "failed to launch: \(error)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
