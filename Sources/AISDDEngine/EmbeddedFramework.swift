import Foundation

/// The framework — the skill set + the `pre-commit` integrity-hook source — embedded into the binary
/// as SwiftPM bundle resources, so the tool can reconcile a repo with NO ai-sdd source clone on disk.
///
/// The repo-root `skills/` and `hooks/pre-commit` remain the single source of truth; symlinks under
/// `Sources/AISDDEngine/Resources/` pull them into `Bundle.module` at build time (declared as
/// `.copy(...)` resources in `Package.swift`). Every read here goes through `Bundle.module` — this
/// type makes no assumption that the repo-root files exist at runtime.
///
/// Shaped like the other deterministic helpers (`SkillSurface`): a `public enum` of statics, no state.
public enum EmbeddedFramework {
    /// A failure reading or materializing an embedded resource. Typed (per the swift conventions:
    /// prefer exact errors over `any Error`) so callers can branch on the missing piece.
    public enum EmbeddedError: Error, Equatable {
        /// The bundled `skills` resource directory is missing — the binary was built without the
        /// `.copy("Resources/skills")` resource, or the bundle is corrupt.
        case skillsResourceMissing
        /// A named skill (or its `SKILL.md`) is absent from the bundle.
        case skillMissing(String)
        /// The bundled `hooks/pre-commit` source is missing.
        case hookResourceMissing
    }

    // MARK: - Bundle locations

    /// The bundled `skills` directory URL inside `Bundle.module`, or nil if the resource is absent.
    private static var skillsRootURL: URL? {
        Bundle.module.url(forResource: Layout.embeddedSkillsResourceDir, withExtension: nil)
    }

    /// The bundled `hooks/pre-commit` source URL inside `Bundle.module`, or nil if absent.
    private static var hookSourceURL: URL? {
        Bundle.module.url(forResource: Layout.embeddedHookFile, withExtension: nil,
                          subdirectory: Layout.embeddedHookResourceDir)
    }

    // MARK: - Enumeration

    /// The embedded framework skill ids, read from the bundle — the subdirectories of the bundled
    /// `skills` dir that contain a `SKILL.md`. Sorted, deduplicated. Derived from bundle contents so
    /// the set self-updates when a later slice embeds another skill. Empty if the resource is absent.
    public static func skillIds() -> [String] {
        guard let root = skillsRootURL else { return [] }
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return entries.compactMap { entry -> String? in
            let manifest = entry.appendingPathComponent(Layout.skillManifestFile)
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  fm.fileExists(atPath: manifest.path) else { return nil }
            return entry.lastPathComponent
        }.sorted()
    }

    // MARK: - Per-skill contents

    /// The bundle URL of a skill's directory, validating it exists and carries a `SKILL.md`.
    private static func skillDirURL(_ id: String) throws -> URL {
        guard let root = skillsRootURL else { throw EmbeddedError.skillsResourceMissing }
        let dir = root.appendingPathComponent(id, isDirectory: true)
        let manifest = dir.appendingPathComponent(Layout.skillManifestFile)
        guard FileManager.default.fileExists(atPath: manifest.path) else {
            throw EmbeddedError.skillMissing(id)
        }
        return dir
    }

    /// One embedded skill's `SKILL.md` contents, read from the bundle.
    public static func skillManifest(_ id: String) throws -> Data {
        let manifest = try skillDirURL(id).appendingPathComponent(Layout.skillManifestFile)
        return try Data(contentsOf: manifest)
    }

    /// Every file under one embedded skill's directory, keyed by its path relative to the skill dir
    /// (e.g. `SKILL.md`, or a nested `reference/foo.md`). Read from the bundle.
    public static func skillFiles(_ id: String) throws -> [String: Data] {
        let dir = try skillDirURL(id)
        let fm = FileManager.default
        var files: [String: Data] = [:]
        let base = dir.standardizedFileURL.path
        let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey])
        while let item = enumerator?.nextObject() as? URL {
            guard (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { continue }
            var relative = item.standardizedFileURL.path
            if relative.hasPrefix(base) {
                relative = String(relative.dropFirst(base.count))
                relative = relative.drop(while: { $0 == "/" }).description
            }
            files[relative] = try Data(contentsOf: item)
        }
        return files
    }

    // MARK: - Hook source

    /// The embedded `pre-commit` integrity-hook source, read from the bundle.
    public static func hookSource() throws -> Data {
        guard let url = hookSourceURL else { throw EmbeddedError.hookResourceMissing }
        return try Data(contentsOf: url)
    }

    // MARK: - Materialize

    /// Write the embedded framework into `directory`: every skill as `<id>/SKILL.md` (and any other
    /// files the skill carries, preserving their relative layout) plus the `pre-commit` hook source as
    /// `<embeddedHookResourceDir>/<embeddedHookFile>`. Intermediate dirs are created; existing files
    /// are overwritten. Reads exclusively from `Bundle.module` — no source clone required.
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
