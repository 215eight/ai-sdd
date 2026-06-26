import Foundation

/// The framework — the skill set + the `pre-commit` integrity-hook source — compiled into the binary
/// as base64 literals (the GITIGNORED, generated `EmbeddedFrameworkData`), so the tool can reconcile a
/// repo with NO ai-sdd source clone AND no sibling resource bundle on disk.
///
/// The repo-root `skills/` and `hooks/pre-commit` remain the single source of truth;
/// `scripts/gen-embedded-resources.sh` (manual infra, sibling to `gen-version.sh`) packs them into the
/// generated `EmbeddedFrameworkData` enum the `AISDDEngine` target compiles in. Every read here decodes
/// from that compiled-in data — no `Bundle.module`, no relocated-bundle lookup — so a lone, relocated
/// `ai-sdd` binary (no `.build`, no `ai-sdd_AISDDEngine.bundle`, no clone) can seed and update.
///
/// Shaped like the other deterministic helpers (`SkillSurface`): a `public enum` of statics, no state.
public enum EmbeddedFramework {
    /// A failure reading or materializing an embedded resource. Typed (per the swift conventions:
    /// prefer exact errors over `any Error`) so callers can branch on the missing piece.
    public enum EmbeddedError: Error, Equatable {
        /// The compiled-in skills pack is empty — the binary was built without the generated
        /// `EmbeddedFrameworkData` source (run `scripts/gen-embedded-resources.sh` before building).
        case skillsResourceMissing
        /// A named skill is absent from the compiled-in pack, or its base64 `SKILL.md` failed to decode.
        case skillMissing(String)
        /// The compiled-in `pre-commit` hook source is absent or failed to base64-decode.
        case hookResourceMissing
    }

    // MARK: - Enumeration

    /// The embedded framework skill ids, read from the compiled-in pack — sorted, deduplicated. Derived
    /// from `EmbeddedFrameworkData.skills` so the set self-updates when a later slice embeds another
    /// skill. Empty if the generated pack is absent. Matches `Layout.embeddedFrameworkSkillIds`.
    public static func skillIds() -> [String] {
        Array(Set(EmbeddedFrameworkData.skills.map(\.id))).sorted()
    }

    // MARK: - Per-skill contents

    /// One embedded skill's `SKILL.md` contents, base64-decoded from the compiled-in pack.
    public static func skillManifest(_ id: String) throws -> Data {
        guard !EmbeddedFrameworkData.skills.isEmpty else { throw EmbeddedError.skillsResourceMissing }
        guard let entry = EmbeddedFrameworkData.skills.first(where: { $0.id == id }),
              let data = Data(base64Encoded: entry.base64) else {
            throw EmbeddedError.skillMissing(id)
        }
        return data
    }

    /// Every file under one embedded skill, keyed by its path relative to the skill dir. Each framework
    /// skill is exactly one `SKILL.md`, so this is a single-entry map keyed by `Layout.skillManifestFile`.
    public static func skillFiles(_ id: String) throws -> [String: Data] {
        [Layout.skillManifestFile: try skillManifest(id)]
    }

    // MARK: - Hook source

    /// The embedded `pre-commit` integrity-hook source, base64-decoded from the compiled-in pack.
    public static func hookSource() throws -> Data {
        guard let data = Data(base64Encoded: EmbeddedFrameworkData.preCommitHookBase64) else {
            throw EmbeddedError.hookResourceMissing
        }
        return data
    }

    // MARK: - Materialize

    /// Write the embedded framework into `directory`: every skill as `<id>/SKILL.md` (and any other
    /// files the skill carries, preserving their relative layout) plus the `pre-commit` hook source as
    /// `<embeddedHookResourceDir>/<embeddedHookFile>`. Intermediate dirs are created; existing files
    /// are overwritten. Reads exclusively from the compiled-in pack — no source clone or bundle required.
    public static func materialize(to directory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let skillsRoot = directory.appendingPathComponent(Layout.embeddedSkillsResourceDir,
                                                           isDirectory: true)
        for id in skillIds() {
            let skillDir = skillsRoot.appendingPathComponent(id, isDirectory: true)
            for (relative, data) in try skillFiles(id) {
                let dest = skillDir.appendingPathComponent(relative)
                try fm.createDirectory(at: dest.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try data.write(to: dest)
            }
        }

        let hookDir = directory.appendingPathComponent(Layout.embeddedHookResourceDir,
                                                       isDirectory: true)
        try fm.createDirectory(at: hookDir, withIntermediateDirectories: true)
        try hookSource().write(to: hookDir.appendingPathComponent(Layout.embeddedHookFile))
    }
}
