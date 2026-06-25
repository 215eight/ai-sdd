import Testing
import Foundation
@testable import AISDDEngine

/// `Seeder` reconciles a target repo from the embedded framework. Every test runs over a fresh
/// UUID-named temp dir (removed in `defer`) — NEVER the real repo, no network, no source clone. A
/// "git" target is just a `<target>/.git/hooks` directory (no real `git` invocation needed).
struct SeederTests {
    /// A fresh UUID-named temp dir.
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-sdd-seed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Make `<dir>/.git/hooks` so the hook-install step runs.
    private func makeGitDir(_ root: URL) throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git/hooks", isDirectory: true),
            withIntermediateDirectories: true)
    }

    private func readJSON(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The SessionStart entries in an agent config (or empty).
    private func sessionStartEntries(_ root: [String: Any]) -> [[String: Any]] {
        let hooks = root[Layout.hooksKey] as? [String: Any] ?? [:]
        return hooks[Layout.sessionStartKey] as? [[String: Any]] ?? []
    }

    /// How many SessionStart entries carry the `ai-sdd update --check` command.
    private func updateCheckCount(_ root: [String: Any]) -> Int {
        sessionStartEntries(root).filter { entry in
            let inner = entry[Layout.hooksKey] as? [[String: Any]] ?? []
            return inner.contains { ($0["command"] as? String) == Layout.updateCheckCommand }
        }.count
    }

    // MARK: - AC1, AC2, AC4, AC6: a fresh seed writes all four artifact groups

    @Test("a fresh seed writes skills+symlinks, hook source+install, both agent configs, and VERSION")
    func freshSeedWritesEverything() throws {
        let target = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: target) }
        try makeGitDir(target)
        let fm = FileManager.default

        try Seeder.reconcile(target: target, version: "1.2.3")

        // AC1: every embedded skill materialized under .ai-sdd/skills/<id>, agent symlinks resolve in.
        let skillsRoot = target.appendingPathComponent(Layout.skillsSource, isDirectory: true)
        let ids = EmbeddedFramework.skillIds()
        #expect(!ids.isEmpty)
        for id in ids {
            let manifest = skillsRoot.appendingPathComponent(id).appendingPathComponent(Layout.skillManifestFile)
            #expect(fm.fileExists(atPath: manifest.path), "missing materialized skill \(id)")
            for (_, agentDir) in Layout.agentSkillSurfaces {
                let link = target.appendingPathComponent(agentDir).appendingPathComponent(id)
                let dest = try #require(try? fm.destinationOfSymbolicLink(atPath: link.path))
                #expect(dest == Layout.skillSurfaceTarget(id))
            }
        }

        // AC2: hook source materialized (with marker) AND installed into .git/hooks/pre-commit.
        let hookSource = target.appendingPathComponent(Layout.homeHookPath)
        #expect(fm.fileExists(atPath: hookSource.path))
        let installed = target.appendingPathComponent(Layout.gitPreCommitHook)
        #expect(fm.fileExists(atPath: installed.path))
        let installedText = try String(contentsOf: installed, encoding: .utf8)
        #expect(installedText.contains(Layout.managedHookMarker))
        #expect(try Data(contentsOf: installed) == EmbeddedFramework.hookSource())

        // AC4: both agent configs hold the SessionStart `ai-sdd update --check` hook.
        let claude = try readJSON(target.appendingPathComponent(Layout.claudeSettingsPath))
        #expect(updateCheckCount(claude) == 1)
        let codex = try readJSON(target.appendingPathComponent(Layout.codexHooksPath))
        #expect(updateCheckCount(codex) == 1)
        // Codex carries the matcher; Claude does not.
        let codexEntry = try #require(sessionStartEntries(codex).first)
        #expect(codexEntry["matcher"] as? String == Layout.codexSessionMatcher)
        #expect(sessionStartEntries(claude).first?["matcher"] == nil)

        // AC6: VERSION == the injected string, verbatim.
        let version = try String(
            contentsOf: target.appendingPathComponent(Layout.versionStampPath), encoding: .utf8)
        #expect(version == "1.2.3")
    }

    // MARK: - AC2: .git absent → install skipped without error

    @Test("seed without a .git skips the hook install but still writes the home hook source")
    func seedWithoutGitSkipsInstall() throws {
        let target = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: target) }
        let fm = FileManager.default

        try Seeder.reconcile(target: target, version: "0.0.1")

        #expect(fm.fileExists(atPath: target.appendingPathComponent(Layout.homeHookPath).path))
        #expect(!fm.fileExists(atPath: target.appendingPathComponent(Layout.gitPreCommitHook).path))
    }

    // MARK: - AC7: a second seed does not duplicate

    @Test("a second seed refreshes without duplicating symlinks or session-hook entries")
    func secondSeedNoDuplication() throws {
        let target = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: target) }
        try makeGitDir(target)

        try Seeder.reconcile(target: target, version: "2.0.0")
        try Seeder.reconcile(target: target, version: "2.0.0")

        // No duplicate session-hook entries.
        #expect(updateCheckCount(try readJSON(target.appendingPathComponent(Layout.claudeSettingsPath))) == 1)
        #expect(updateCheckCount(try readJSON(target.appendingPathComponent(Layout.codexHooksPath))) == 1)

        // Symlinks reconcile to unchanged (no re-creation churn that would signal duplication).
        let result = try SkillSurface.reconcile(repoRoot: target, check: true)
        #expect(result.reconciled)

        // Managed hook still installed and carries the marker (refreshed, not re-chained).
        let installed = target.appendingPathComponent(Layout.gitPreCommitHook)
        let text = try String(contentsOf: installed, encoding: .utf8)
        #expect(text.contains(Layout.managedHookMarker))
    }

    // MARK: - AC3: a foreign pre-commit hook is chained exactly once

    @Test("a pre-existing foreign hook is moved to .pre-commit.local exactly once, preserved on reseed")
    func foreignHookChainedOnce() throws {
        let target = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: target) }
        try makeGitDir(target)
        let fm = FileManager.default

        // Plant a foreign (non-managed) pre-commit hook.
        let foreignBody = "#!/bin/sh\necho my-own-hook\n"
        let dest = target.appendingPathComponent(Layout.gitPreCommitHook)
        try Data(foreignBody.utf8).write(to: dest)

        try Seeder.reconcile(target: target, version: "1.0.0")

        // The foreign hook was chained once; the managed hook took its place.
        let chained = target.appendingPathComponent(Layout.gitChainedHook)
        #expect(fm.fileExists(atPath: chained.path))
        #expect(try String(contentsOf: chained, encoding: .utf8) == foreignBody)
        #expect(try String(contentsOf: dest, encoding: .utf8).contains(Layout.managedHookMarker))

        // A second seed neither re-chains nor overwrites .pre-commit.local.
        try Seeder.reconcile(target: target, version: "1.0.0")
        #expect(try String(contentsOf: chained, encoding: .utf8) == foreignBody)
        #expect(try String(contentsOf: dest, encoding: .utf8).contains(Layout.managedHookMarker))
    }

    // MARK: - AC5: unrelated keys preserved through the JSON merge

    @Test("an unrelated key in an existing agent config is preserved through the merge")
    func unrelatedKeysPreserved() throws {
        let target = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: target) }
        let fm = FileManager.default

        // Pre-seed a Claude settings file with an unrelated top-level key.
        let claudePath = target.appendingPathComponent(Layout.claudeSettingsPath)
        try fm.createDirectory(at: claudePath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["model": "opus", "theme": "dark"])
            .write(to: claudePath)

        try Seeder.reconcile(target: target, version: "3.1.4")
        // A second seed must still preserve and not duplicate.
        try Seeder.reconcile(target: target, version: "3.1.4")

        let claude = try readJSON(claudePath)
        #expect(claude["model"] as? String == "opus")
        #expect(claude["theme"] as? String == "dark")
        #expect(updateCheckCount(claude) == 1)
    }

    // MARK: - typed error on a non-directory target

    @Test("seeding a non-directory target throws the typed targetNotADirectory error")
    func nonDirectoryTargetThrows() throws {
        let bogus = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-sdd-seed-missing-\(UUID().uuidString)", isDirectory: true)
        #expect(throws: Seeder.SeedError.targetNotADirectory(bogus.standardizedFileURL.path)) {
            try Seeder.reconcile(target: bogus, version: "0.0.0")
        }
    }

    // MARK: - the materialized skill set equals the embedded set (AC1 set equality)

    @Test("the materialized skill set equals EmbeddedFramework.skillIds()")
    func skillSetEqualsEmbedded() throws {
        let target = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: target) }

        try Seeder.reconcile(target: target, version: "0.9.0")

        let skillsRoot = target.appendingPathComponent(Layout.skillsSource, isDirectory: true)
        let materialized = (try FileManager.default.contentsOfDirectory(
            at: skillsRoot, includingPropertiesForKeys: [.isDirectoryKey]))
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .sorted()
        #expect(materialized == EmbeddedFramework.skillIds())
    }
}
