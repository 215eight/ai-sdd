import Foundation
import AISDDModels

/// The verdict of one Check (architecture.md §8).
public struct CheckResult: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Equatable, Sendable {
        case passed      // a deterministic command exited 0
        case failed      // a deterministic command exited non-zero
        case deferred    // judge/human — not runnable yet, never blocks
    }

    public var check: String
    public var status: Status
    public var required: Bool      // a failing required check blocks (triggers rework)
    public var exitCode: Int32?
    public var output: String?     // trimmed command output, kept on failure for the rework render

    public init(check: String, status: Status, required: Bool,
                exitCode: Int32? = nil, output: String? = nil) {
        self.check = check
        self.status = status
        self.required = required
        self.exitCode = exitCode
        self.output = output
    }

    /// A required check that did not pass — the engine blocks on these and routes to rework.
    public var isBlockingFailure: Bool { status == .failed && required }
}

/// The single executor for checks (architecture.md §8). For this slice it runs `deterministic`
/// checks as commands in the workspace and reads their exit status; `judge`/`human` checks are
/// recorded as `deferred` (the Adapter / human-gate that runs them lands later) and never block.
/// The engine — not the agent — runs the gate and reads the result (gating is engine-enforced).
public struct CheckRunner: Sendable {
    public let workingDirectory: URL
    /// Injectable command execution so tests don't shell out. Returns (exitCode, combined output).
    public var execute: @Sendable (_ command: String, _ cwd: URL) -> (Int32, String)

    public init(workingDirectory: URL,
                execute: @escaping @Sendable (_ command: String, _ cwd: URL) -> (Int32, String) = CheckRunner.shell) {
        self.workingDirectory = workingDirectory
        self.execute = execute
    }

    /// Run the given checks (by id) against their specs, in declaration order.
    public func run(_ checkIDs: [String], specs: [String: CheckSpec]) -> [CheckResult] {
        checkIDs.map { id in
            let spec = specs[id]
            let required = spec?.required ?? true
            switch spec?.checkKind {
            case "deterministic":
                guard let command = spec?.command else {
                    // A deterministic check with no command is a misconfiguration, not a pass.
                    return CheckResult(check: id, status: .failed, required: required,
                                       output: "deterministic check has no command")
                }
                let (code, output) = execute(command, workingDirectory)
                return CheckResult(check: id, status: code == 0 ? .passed : .failed,
                                   required: required, exitCode: code,
                                   output: code == 0 ? nil : trimmed(output))
            default:
                // judge / human (or unspecified): deferred, non-blocking for now.
                return CheckResult(check: id, status: .deferred, required: required)
            }
        }
    }

    /// The default executor: run `command` via `/bin/sh -c` in `cwd`, capturing stdout+stderr.
    public static let shell: @Sendable (_ command: String, _ cwd: URL) -> (Int32, String) = { command, cwd in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = cwd
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (127, "failed to launch: \(error)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func trimmed(_ output: String) -> String {
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.count > 2000 ? String(value.suffix(2000)) : value
    }
}
