import Testing
import Foundation
@testable import AISDDEngine

/// The framework is COMPILED INTO the binary as base64 literals (the gitignored generated
/// `EmbeddedFrameworkData`), so these tests touch ONLY that compiled-in data and a temp dir — no
/// network, no source clone, no `Bundle.module`, and no sibling resource bundle on disk.
struct EmbeddedFrameworkTests {
    @Test("enumerates exactly the expected framework skill ids from the compiled-in pack")
    func skillIdsMatchExpected() {
        #expect(EmbeddedFramework.skillIds() == Layout.embeddedFrameworkSkillIds)
        // Seven framework skills, including ai-sdd-update.
        #expect(EmbeddedFramework.skillIds().count == 7)
        #expect(EmbeddedFramework.skillIds().contains("ai-sdd-update"))
    }

    @Test("every embedded skill returns a non-empty SKILL.md from the compiled-in pack")
    func everySkillHasNonEmptyManifest() throws {
        for id in EmbeddedFramework.skillIds() {
            let manifest = try EmbeddedFramework.skillManifest(id)
            #expect(!manifest.isEmpty, "SKILL.md for \(id) should be non-empty")
        }
    }

    @Test("skillFiles returns a single SKILL.md entry keyed by the manifest name")
    func skillFilesIsSingleManifest() throws {
        for id in EmbeddedFramework.skillIds() {
            let files = try EmbeddedFramework.skillFiles(id)
            #expect(Array(files.keys) == [Layout.skillManifestFile])
            #expect(try files[Layout.skillManifestFile] == EmbeddedFramework.skillManifest(id))
        }
    }

    @Test("the embedded pre-commit hook source is non-empty and carries the managed-hook marker")
    func hookSourceHasMarker() throws {
        let data = try EmbeddedFramework.hookSource()
        #expect(!data.isEmpty)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains(Layout.managedHookMarker))
    }

    /// The whole point of the slice: the framework is served PURELY from compiled-in data — all 7 ids,
    /// every non-empty SKILL.md, and the hook source — with no resource bundle present on disk.
    @Test("serves all 7 ids + non-empty SKILL.md + hook purely from compiled-in data, no bundle")
    func compiledInWithoutBundle() throws {
        let ids = EmbeddedFramework.skillIds()
        #expect(ids == Layout.embeddedFrameworkSkillIds)
        #expect(ids.count == 7)

        for id in ids {
            #expect(!(try EmbeddedFramework.skillManifest(id)).isEmpty)
        }

        let hook = try EmbeddedFramework.hookSource()
        #expect(!hook.isEmpty)
        let hookText = try #require(String(data: hook, encoding: .utf8))
        #expect(hookText.contains(Layout.managedHookMarker))

        // No `ai-sdd_AISDDEngine.bundle` exists beside the test binary — the data is compiled in, not
        // loaded from a SwiftPM resource bundle.
        let testBinaryDir = URL(fileURLWithPath: Bundle.main.bundlePath).deletingLastPathComponent()
        let bundle = testBinaryDir.appendingPathComponent("ai-sdd_AISDDEngine.bundle")
        #expect(!FileManager.default.fileExists(atPath: bundle.path))
    }

    @Test("an unknown skill id throws the typed skillMissing error")
    func unknownSkillThrows() {
        #expect(throws: EmbeddedFramework.EmbeddedError.skillMissing("does-not-exist")) {
            _ = try EmbeddedFramework.skillManifest("does-not-exist")
        }
    }

    @Test("materialize writes <id>/SKILL.md + the hook, matching the in-memory accessor contents")
    func materializeRoundTrips() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("ai-sdd-embedded-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }

        try EmbeddedFramework.materialize(to: dir)

        // Every skill's SKILL.md was written under skills/<id>/SKILL.md and matches the accessor.
        let skillsRoot = dir.appendingPathComponent(Layout.embeddedSkillsResourceDir, isDirectory: true)
        for id in EmbeddedFramework.skillIds() {
            let written = skillsRoot
                .appendingPathComponent(id, isDirectory: true)
                .appendingPathComponent(Layout.skillManifestFile)
            #expect(fm.fileExists(atPath: written.path), "missing materialized SKILL.md for \(id)")
            #expect(try Data(contentsOf: written) == EmbeddedFramework.skillManifest(id))
        }

        // The hook was written under hooks/pre-commit and matches the accessor.
        let writtenHook = dir
            .appendingPathComponent(Layout.embeddedHookResourceDir, isDirectory: true)
            .appendingPathComponent(Layout.embeddedHookFile)
        #expect(fm.fileExists(atPath: writtenHook.path))
        #expect(try Data(contentsOf: writtenHook) == EmbeddedFramework.hookSource())
    }
}
