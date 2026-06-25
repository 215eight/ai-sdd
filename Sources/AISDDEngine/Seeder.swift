import Foundation

/// `Seeder` is the binary-native, no-clone successor to `scripts/bootstrap.sh`: it idempotently
/// reconciles a target repo entirely from the embedded framework (`EmbeddedFramework` / `Bundle.module`),
/// with every filesystem effect confined to paths under `target`. It reads no ai-sdd source clone.
///
/// Shaped like the other deterministic engine helpers (`SkillSurface` / `EmbeddedFramework`): a
/// `public enum` of statics, no stored state. The version value is *injected* by the CLI
/// (`AISDDVersion.current`) so the engine never references the gitignored CLI build product and stays a
/// clean layer below it.
///
/// The five steps mirror `bootstrap.sh` and the plan's scope:
///   1. materialize the embedded skills into `<target>/.ai-sdd/skills` + reconcile the agent symlinks
///      (reusing `EmbeddedFramework.materialize` + `SkillSurface.reconcile`);
///   2. install/refresh `<target>/.git/hooks/pre-commit` from the materialized hook source, chaining a
///      foreign hook exactly once via the managed-hook marker (skipped when `<target>/.git` is absent);
///   3. merge an idempotent SessionStart hook running `ai-sdd update --check` into the Claude and Codex
///      agent configs;
///   4. stamp `<target>/.ai-sdd/VERSION` with the injected version;
/// (step 5 — onboarding-doc edits — is a one-time committed change, not a per-seed effect.)
public enum Seeder {
    /// A typed failure reconciling a target (per the swift conventions: prefer exact errors over
    /// `any Error`). Embedded-resource failures surface as `EmbeddedFramework.EmbeddedError`.
    public enum SeedError: Error, Equatable {
        /// The resolved target is not an existing directory.
        case targetNotADirectory(String)
    }

    /// One reported step of a seed (for the CLI's per-step summary). `detail` is a short human line.
    public struct StepReport: Equatable {
        public let title: String
        public let detail: String
        public init(title: String, detail: String) {
            self.title = title
            self.detail = detail
        }
    }

    /// Reconcile `target` from the embedded framework, stamping `version`. Idempotent: a second seed
    /// refreshes the materialized skills + hook, adds only what's missing for the symlinks and the
    /// installed hook (a foreign hook is chained exactly once), de-duplicates the agent session hooks,
    /// and rewrites VERSION to the same value. Returns a per-step report for the caller to print.
    @discardableResult
    public static func reconcile(target: URL, version: String) throws -> [StepReport] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: target.path, isDirectory: &isDir), isDir.boolValue else {
            throw SeedError.targetNotADirectory(target.path)
        }
        let target = target.standardizedFileURL

        var reports: [StepReport] = []
        reports.append(try materializeSkills(target: target))
        reports.append(try installHook(target: target))
        reports.append(try mergeSessionHook(
            target: target, config: target.appendingPathComponent(Layout.claudeSettingsPath),
            matcher: nil, label: "Claude (.claude/settings.json)"))
        reports.append(try mergeSessionHook(
            target: target, config: target.appendingPathComponent(Layout.codexHooksPath),
            matcher: Layout.codexSessionMatcher, label: "Codex (.codex/hooks.json)"))
        reports.append(try stampVersion(target: target, version: version))
        return reports
    }

    // MARK: - Step 1: skills + symlinks

    /// Materialize the embedded skills (and the hook source) under `<target>/.ai-sdd`, then reconcile
    /// the per-agent symlinks via `SkillSurface` (clean create/fix/prune; never clobbers non-managed
    /// entries). Seed does NOT reimplement symlinking.
    static func materializeSkills(target: URL) throws -> StepReport {
        let home = target.appendingPathComponent(Layout.homeDir, isDirectory: true)
        try EmbeddedFramework.materialize(to: home)
        let result = try SkillSurface.reconcile(repoRoot: target, check: false)
        let changed = result.ops.filter(\.mutates).count
        let ids = EmbeddedFramework.skillIds()
        return StepReport(
            title: "Materialize framework skills → .ai-sdd/skills/ (+ agent symlinks)",
            detail: "\(ids.count) skill(s); "
                + (changed == 0 ? "symlinks already reconciled" : "reconciled \(changed) symlink(s)"))
    }

    // MARK: - Step 2: pre-commit hook

    /// Install/refresh `<target>/.git/hooks/pre-commit` from the materialized hook source, replicating
    /// `bootstrap.sh`'s managed-hook chaining. Skipped (no error) when `<target>/.git` is absent.
    static func installHook(target: URL) throws -> StepReport {
        let fm = FileManager.default
        let gitDir = target.appendingPathComponent(Layout.gitDir, isDirectory: true)
        guard fm.fileExists(atPath: gitDir.path) else {
            return StepReport(title: "Install pre-commit hook → .git/hooks/pre-commit",
                              detail: "skipped — no .git")
        }
        let source = target.appendingPathComponent(Layout.homeHookPath)
        let dest = target.appendingPathComponent(Layout.gitPreCommitHook)
        let chained = target.appendingPathComponent(Layout.gitChainedHook)
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)

        let detail: String
        if fm.fileExists(atPath: dest.path), hookCarriesMarker(at: dest) {
            try copyOverwriting(from: source, to: dest)              // managed hook present → refresh
            detail = "refreshed the managed hook"
        } else if fm.fileExists(atPath: dest.path) {                 // a foreign hook
            if !fm.fileExists(atPath: chained.path) {                // chain it exactly once
                try fm.moveItem(at: dest, to: chained)
                try makeExecutable(chained)
            }
            try copyOverwriting(from: source, to: dest)
            detail = "installed the managed hook (chaining your prior hook → .pre-commit.local)"
        } else {
            try copyOverwriting(from: source, to: dest)
            detail = "installed"
        }
        try makeExecutable(dest)
        if fm.fileExists(atPath: chained.path) { try makeExecutable(chained) }
        return StepReport(title: "Install pre-commit hook → .git/hooks/pre-commit", detail: detail)
    }

    /// Whether the file at `url` carries the managed-hook marker (so it is ours to refresh in place).
    private static func hookCarriesMarker(at url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return text.contains(Layout.managedHookMarker)
    }

    private static func copyOverwriting(from source: URL, to dest: URL) throws {
        let data = try Data(contentsOf: source)
        try data.write(to: dest)
    }

    private static func makeExecutable(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    // MARK: - Step 3: agent SessionStart hooks

    /// Idempotently merge a SessionStart hook running `ai-sdd update --check` into one agent config
    /// JSON file, preserving unrelated keys and unrelated SessionStart entries and never duplicating
    /// the managed entry. `matcher` is the Codex `"startup|resume"` (nil for Claude, which needs none).
    static func mergeSessionHook(target: URL, config: URL, matcher: String?, label: String) throws
        -> StepReport {
        let fm = FileManager.default
        // Read the existing file as JSON; treat missing/empty/unparseable as an empty object.
        var root: [String: Any] = {
            guard let data = try? Data(contentsOf: config), !data.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return [:] }
            return obj
        }()

        var hooks = root[Layout.hooksKey] as? [String: Any] ?? [:]
        var sessionStart = hooks[Layout.sessionStartKey] as? [[String: Any]] ?? []

        let alreadyPresent = sessionStart.contains { entry in
            let inner = entry[Layout.hooksKey] as? [[String: Any]] ?? []
            return inner.contains { ($0["command"] as? String) == Layout.updateCheckCommand }
        }

        let detail: String
        if alreadyPresent {
            detail = "\(label): up to date"
        } else {
            var entry: [String: Any] = [
                Layout.hooksKey: [["type": "command", "command": Layout.updateCheckCommand]]
            ]
            if let matcher { entry["matcher"] = matcher }
            sessionStart.append(entry)
            hooks[Layout.sessionStartKey] = sessionStart
            root[Layout.hooksKey] = hooks

            try fm.createDirectory(at: config.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            let data = try JSONSerialization.data(
                withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: config)
            detail = "\(label): installed SessionStart hook"
        }
        return StepReport(title: "Merge agent SessionStart hook (ai-sdd update --check)", detail: detail)
    }

    // MARK: - Step 4: VERSION stamp

    /// Write the injected version string verbatim to `<target>/.ai-sdd/VERSION` (no extra framing).
    static func stampVersion(target: URL, version: String) throws -> StepReport {
        let home = target.appendingPathComponent(Layout.homeDir, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let dest = home.appendingPathComponent(Layout.versionStampFile)
        try Data(version.utf8).write(to: dest)
        return StepReport(title: "Stamp .ai-sdd/VERSION", detail: version)
    }
}
