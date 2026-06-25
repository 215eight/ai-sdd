import Testing
import Foundation
@testable import AISDDEngine

/// The framework is embedded in the binary as bundle resources, so these tests touch ONLY
/// `Bundle.module` and a temp dir — no network, no source clone, no repo-root filesystem reads.
struct EmbeddedFrameworkTests {
    @Test("enumerates exactly the expected framework skill ids from the bundle")
    func skillIdsMatchExpected() {
        #expect(EmbeddedFramework.skillIds() == Layout.embeddedFrameworkSkillIds)
    }

    @Test("every embedded skill returns a non-empty SKILL.md from the bundle")
    func everySkillHasNonEmptyManifest() throws {
        for id in EmbeddedFramework.skillIds() {
            let manifest = try EmbeddedFramework.skillManifest(id)
            #expect(!manifest.isEmpty, "SKILL.md for \(id) should be non-empty")
        }
    }

    @Test("the embedded pre-commit hook source is non-empty and carries the managed-hook marker")
    func hookSourceHasMarker() throws {
        let data = try EmbeddedFramework.hookSource()
        #expect(!data.isEmpty)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("ai-sdd:managed-hook"))
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
