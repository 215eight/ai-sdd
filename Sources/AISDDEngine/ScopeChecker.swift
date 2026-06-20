import Foundation
import Yams

/// The Tier-2 scope gate: verify the work touched only files the plan declared. Pure functions
/// (parsing + set arithmetic) so they're testable without a real repo; the CLI runs git and
/// feeds the output in. Crucially this counts **new/untracked** files — a feature is mostly new
/// files, and those are exactly the ones an out-of-scope check must not miss.
public enum ScopeChecker {
    /// The declared manifest: the `files:` list of a plan artifact (YAML).
    public static func declaredFiles(planYAML: String) throws -> [String] {
        let object = try Yams.load(yaml: planYAML) as? [String: Any]
        return (object?["files"] as? [Any])?.compactMap { $0 as? String } ?? []
    }

    /// The set of repo-relative paths the working tree touches — from `git status --porcelain`
    /// (modified, deleted, and untracked/new), plus optionally `git diff --name-status <ref> HEAD`
    /// for changes already committed since a baseline. Both sides of a rename count as touched.
    public static func changedFiles(porcelain: String, committed: String? = nil) -> [String] {
        var paths: Set<String> = []
        for line in porcelain.split(separator: "\n", omittingEmptySubsequences: true) {
            paths.formUnion(parsePorcelain(String(line)))
        }
        for line in (committed ?? "").split(separator: "\n", omittingEmptySubsequences: true) {
            paths.formUnion(parseNameStatus(String(line)))
        }
        return paths.sorted()
    }

    /// Changed files not covered by the manifest (empty == in scope). A change is in scope if it
    /// equals a declared entry, or sits under a declared directory (an entry ending `/` or `/**`).
    public static func outOfScope(changed: [String], declared: [String]) -> [String] {
        let exact = Set(declared.filter { !isPrefix($0) })
        let prefixes = declared.filter(isPrefix).map(normalizePrefix)
        return changed.filter { file in
            !exact.contains(file) && !prefixes.contains(where: file.hasPrefix)
        }
    }

    // MARK: - parsing

    /// `XY <path>` (X/Y status chars), or a rename `… old -> new`.
    private static func parsePorcelain(_ line: String) -> [String] {
        guard line.count > 3 else { return [] }
        let rest = String(line.dropFirst(3))
        if rest.contains(" -> ") {
            return rest.components(separatedBy: " -> ").map(unquote)
        }
        return [unquote(rest)]
    }

    /// `M<TAB>path`, `A<TAB>path`, `D<TAB>path`, or `R100<TAB>old<TAB>new`.
    private static func parseNameStatus(_ line: String) -> [String] {
        let cols = line.split(separator: "\t").map(String.init)
        guard cols.count >= 2 else { return [] }
        return cols.dropFirst().map(unquote)
    }

    private static func isPrefix(_ entry: String) -> Bool { entry.hasSuffix("/") || entry.hasSuffix("/**") }
    private static func normalizePrefix(_ entry: String) -> String {
        var path = entry
        if path.hasSuffix("**") { path.removeLast(2) }
        if !path.hasSuffix("/") { path += "/" }
        return path
    }
    private static func unquote(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }
}
