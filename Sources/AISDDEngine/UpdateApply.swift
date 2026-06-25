import Foundation
import CryptoKit

/// The apply half of self-update (the detect half is `UpdateCheck`). `UpdateApply` is a pure
/// `AISDDEngine` helper — a `public enum` of statics with no stored state, shaped like
/// `UpdateCheck` / `Seeder`: every effect (asset resolution, byte download, checksum, archive
/// extraction, filesystem move, reseed, the running version, the install path) is *injected*, so the
/// engine never reaches the real network, never touches the real `~/.local/bin`, never imports the
/// gitignored CLI build product, and is exercised entirely over fakes + temp dirs.
///
/// Flow (all effects on injected seams):
///   1. resolve `releases/latest` → typed `ResolvedAssets` (tag + tarball URL + `.sha256` URL).
///   2. compare the resolved tag to the running version (`SemanticVersion`): not strictly newer →
///      `.upToDate` no-op (no download / extract / move / reseed).
///   3. download the tarball bytes + the sidecar bytes.
///   4. verify the tarball's sha256 against the sidecar — ABORT fail-closed on mismatch BEFORE any
///      move; the current binary + `.ai-sdd/VERSION` stay byte-for-byte untouched.
///   5. extract the tarball to a temp dir → the unpacked binary URL.
///   6. atomically self-replace the install path: the mover stages a temp file in the SAME dir as the
///      target and renames it over the target (the single commit point).
///   7. invoke the injected reseed hook with the resolved tag's stamped version (refreshes skills /
///      hooks / `.ai-sdd/VERSION`).
///
/// Any failure before the rename leaves the current binary + VERSION untouched. The result type
/// carries the from/to versions for the CLI's stderr summary; the typed error enum is mapped by the
/// CLI to a clear one-line stderr message + a non-zero exit.
public enum UpdateApply {

    // MARK: - Typed errors

    /// The exact failure modes of the apply flow (per the swift conventions: exact typed errors, not
    /// `any Error`). Each maps to a clear CLI stderr message + a non-zero exit. The already-up-to-date
    /// no-op is NOT an error — it is carried in `Outcome` and exits 0.
    public enum ApplyError: Error, Equatable, Sendable {
        /// `releases/latest` could not be resolved into a tarball + sidecar (offline, non-200,
        /// malformed body, either asset missing). The injected resolver returned `nil`.
        case assetResolutionFailed
        /// The running version string did not parse as a release `SemanticVersion` (a dev build), so
        /// the apply path cannot reason about whether the release is newer. Fail closed.
        case runningVersionUnparseable(String)
        /// A download seam (tarball or sidecar) returned `nil` / threw.
        case downloadFailed(which: String)
        /// The sidecar body did not contain a parseable sha256 hex digest.
        case checksumMalformed
        /// The tarball's computed sha256 did NOT match the sidecar's recorded value — abort before any
        /// move. Carries both digests for a diagnosable message.
        case checksumMismatch(expected: String, actual: String)
        /// The archive extractor failed to produce an unpacked binary.
        case extractFailed
        /// The atomic same-dir move failed (staging or rename). The original target file is intact.
        case moveFailed
        /// The reseed hook threw after a successful replace.
        case reseedFailed
    }

    // MARK: - Outcome

    /// The non-error result of a run: either no work was needed, or an update was applied.
    public enum Outcome: Equatable, Sendable {
        /// The resolved latest release is not strictly newer than the running version — no download /
        /// extract / move / reseed happened. The CLI prints a clear message and exits 0.
        case alreadyUpToDate(running: String, latestTag: String)
        /// An update was applied: the binary was replaced and the reseed hook ran. Carries the
        /// from/to versions for the CLI's `vCURRENT -> vLATEST` stderr summary.
        case applied(from: String, to: String)
    }

    // MARK: - Injected seams

    /// Download the raw bytes for a URL, or `nil` on any failure (fail-closed → a typed download
    /// error). Mirrors `UpdateCheck.ReleaseFetcher`'s injected-closure shape. The CLI binds a real
    /// `URLSession` GET; tests inject a fake returning fixture bytes (or `nil`).
    public typealias Downloader = @Sendable (_ url: URL) -> Data?

    /// Compute the lowercase-hex sha256 of `bytes`. Default `defaultChecksum` uses CryptoKit (the same
    /// `SHA256` `Provenance` uses). Injected so a test can assert verifier wiring without CryptoKit.
    public typealias Checksum = @Sendable (_ bytes: Data) -> String

    /// Extract the tarball at `tarball` into `destDir`, returning the unpacked binary URL, or `nil` on
    /// failure. The CLI binds a `tar` shell-out (the `CheckRunner.shell` pattern); tests inject a fake
    /// that writes a fixture binary into `destDir` and returns its URL.
    public typealias Extractor = @Sendable (_ tarball: URL, _ destDir: URL) -> URL?

    /// Atomically move the unpacked binary at `source` over the install path `target` by staging a
    /// temp file in the SAME directory as `target` then renaming it into place. Throws on any failure
    /// (the CLI binds a `FileManager.replaceItem`/POSIX-rename impl; tests inject fakes — including a
    /// failing one to assert the untouched-on-failure invariant). Returns normally on success.
    public typealias Mover = @Sendable (_ source: URL, _ target: URL) throws -> Void

    /// Re-run seeding for the just-installed version (the CLI binds `Seeder.reconcile(target:version:)`),
    /// refreshing skills / hooks and stamping `.ai-sdd/VERSION`. Injected so the engine never imports
    /// the gitignored CLI version product; tests inject a recording hook.
    public typealias Reseeder = @Sendable (_ version: String) throws -> Void

    // MARK: - Defaults (bound by the CLI; the engine ships these as the real impls)

    /// The default `Downloader`: a synchronous anonymous GET (the same bridge `UpdateCheck.urlSession`
    /// uses), returning the body on a 2xx, else `nil`.
    public static let urlSessionDownloader: Downloader = { url in
        var request = URLRequest(url: url)
        request.setValue(Layout.updateUserAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        final class Box: @unchecked Sendable { var payload: Data? }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                box.payload = data
            }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()
        return box.payload
    }

    /// The default `Checksum`: lowercase-hex CryptoKit SHA-256, matching `Provenance.contentHash`.
    public static let defaultChecksum: Checksum = { bytes in
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// The default `Extractor`: shell `tar -xzf <tarball> -C <destDir>` (the `CheckRunner.shell`
    /// pattern), then locate the unpacked `ai-sdd` binary under `destDir`. Returns `nil` on a non-zero
    /// tar exit or a missing binary.
    public static let tarExtractor: Extractor = { tarball, destDir in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["tar", "-xzf", tarball.path, "-C", destDir.path]
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        // The published tarball unpacks the binary as `ai-sdd` (possibly under a top-level dir); find it.
        let direct = destDir.appendingPathComponent(Layout.updateInstallBinaryName)
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        let enumerator = FileManager.default.enumerator(at: destDir, includingPropertiesForKeys: nil)
        while let item = enumerator?.nextObject() as? URL {
            if item.lastPathComponent == Layout.updateInstallBinaryName { return item }
        }
        return nil
    }

    /// The default `Mover`: stage a temp file beside `target` (SAME dir → atomic rename on one
    /// filesystem) then `FileManager.replaceItemAt` over `target`. Any failure throws `moveFailed`,
    /// leaving the original `target` intact (the rename is the single commit point).
    public static let fileSystemMover: Mover = { source, target in
        let fm = FileManager.default
        let dir = target.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let staged = dir.appendingPathComponent(".ai-sdd-update-\(UUID().uuidString)")
        do {
            // Copy the unpacked binary into the SAME dir as the target, then commit with a rename.
            if fm.fileExists(atPath: staged.path) { try fm.removeItem(at: staged) }
            try fm.copyItem(at: source, to: staged)
            try makeExecutable(staged)
            if fm.fileExists(atPath: target.path) {
                _ = try fm.replaceItemAt(target, withItemAt: staged)
            } else {
                try fm.moveItem(at: staged, to: target)
            }
        } catch {
            try? fm.removeItem(at: staged)
            throw ApplyError.moveFailed
        }
    }

    private static func makeExecutable(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    // MARK: - The apply flow

    /// Resolve → (up-to-date?) → download → verify → extract → atomic-replace → reseed.
    ///
    /// - Parameters:
    ///   - runningVersion: the injected `AISDDVersion.current` string (the CLI binds it).
    ///   - releaseURL: the `releases/latest` URL (default `Layout.latestReleaseURL`).
    ///   - installPath: the on-PATH binary to self-replace (the CLI binds `~/.local/bin/ai-sdd`; tests
    ///     point it at a pre-seeded temp file so the untouched-on-abort invariant is asserted on real bytes).
    ///   - workDir: a scratch dir for downloads + extraction (the CLI binds a temp dir).
    ///   - resolver: the injected `AssetResolver` (default `urlSessionAssetResolver`).
    ///   - downloader: the injected `Downloader` (default `urlSessionDownloader`).
    ///   - checksum: the injected `Checksum` (default `defaultChecksum`).
    ///   - extractor: the injected `Extractor` (default `tarExtractor`).
    ///   - mover: the injected `Mover` (default `fileSystemMover`).
    ///   - reseed: the injected `Reseeder` (the CLI binds `Seeder.reconcile`).
    /// - Returns: the `Outcome` (already-up-to-date or applied).
    /// - Throws: a typed `ApplyError` on any failure; the current binary + VERSION stay untouched
    ///   unless the move's rename committed.
    public static func apply(
        runningVersion: String,
        releaseURL: URL = Layout.latestReleaseURL,
        installPath: URL,
        workDir: URL,
        resolver: UpdateCheck.AssetResolver = UpdateCheck.urlSessionAssetResolver,
        downloader: Downloader = urlSessionDownloader,
        checksum: Checksum = defaultChecksum,
        extractor: Extractor = tarExtractor,
        mover: Mover = fileSystemMover,
        reseed: Reseeder
    ) throws -> Outcome {
        // (0) A dev / unparseable running version cannot be reasoned about — fail closed.
        guard let running = SemanticVersion(runningVersion), running.isRelease else {
            throw ApplyError.runningVersionUnparseable(runningVersion)
        }

        // (1) Resolve the latest release's assets.
        guard let assets = resolver(releaseURL) else { throw ApplyError.assetResolutionFailed }

        // (2) Up-to-date? An unparseable tag is treated as "not newer" → no-op (never act on a
        //     malformed tag). Only a strictly-newer parseable release proceeds.
        guard let latest = SemanticVersion(assets.tag), latest > running else {
            return .alreadyUpToDate(running: runningVersion, latestTag: assets.tag)
        }

        // (3) Download the tarball + the sidecar.
        guard let tarballBytes = downloader(assets.tarballURL) else {
            throw ApplyError.downloadFailed(which: "tarball")
        }
        guard let sidecarBytes = downloader(assets.checksumURL) else {
            throw ApplyError.downloadFailed(which: "checksum")
        }

        // (4) Verify sha256 — ABORT fail-closed on mismatch BEFORE any move / extract.
        guard let expected = parseSha256(sidecarBytes) else { throw ApplyError.checksumMalformed }
        let actual = checksum(tarballBytes).lowercased()
        guard actual == expected else {
            throw ApplyError.checksumMismatch(expected: expected, actual: actual)
        }

        // (5) Stage the verified tarball and extract the unpacked binary.
        let fm = FileManager.default
        try? fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        let tarballURL = workDir.appendingPathComponent(Layout.updateAssetName)
        let extractDir = workDir.appendingPathComponent("extract-\(UUID().uuidString)", isDirectory: true)
        do {
            try tarballBytes.write(to: tarballURL)
            try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
        } catch {
            throw ApplyError.extractFailed
        }
        guard let unpacked = extractor(tarballURL, extractDir) else { throw ApplyError.extractFailed }

        // (6) Atomically self-replace the install path (the single commit point).
        do {
            try mover(unpacked, installPath)
        } catch let error as ApplyError {
            throw error
        } catch {
            throw ApplyError.moveFailed
        }

        // (7) Reseed for the just-installed version (stamped form of the resolved tag).
        let stamped = stampedVersion(forTag: assets.tag)
        do {
            try reseed(stamped)
        } catch {
            throw ApplyError.reseedFailed
        }

        return .applied(from: runningVersion, to: stamped)
    }

    // MARK: - Helpers (pure)

    /// Parse the sidecar body into a lowercase sha256 hex digest. Tolerates the common
    /// `<hex>  <filename>` shasum format (takes the first whitespace-delimited token) and a bare
    /// digest. Returns `nil` if the first token is not exactly 64 hex chars.
    static func parseSha256(_ data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        guard let token = text.split(whereSeparator: { $0.isWhitespace }).first else { return nil }
        let hex = token.lowercased()
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        return hex
    }

    /// The version to stamp after a replace: the resolved release tag normalized to the `X.Y.Z` form
    /// `Seeder.stampVersion` writes (drop a single leading `v`; fall back to the raw tag if it does
    /// not parse). This avoids spawning the just-installed binary to ask its `--version`.
    static func stampedVersion(forTag tag: String) -> String {
        guard let parsed = SemanticVersion(tag) else { return tag }
        return "\(parsed.major).\(parsed.minor).\(parsed.patch)"
    }
}
