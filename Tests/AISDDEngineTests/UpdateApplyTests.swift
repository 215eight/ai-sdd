import Testing
import Foundation
@testable import AISDDEngine

/// Covers the pure `UpdateApply` apply flow + the `UpdateCheck.ResolvedAssets` resolver entirely over
/// injected seams — fake resolver / downloader / extractor / mover / reseed hook + UUID-named temp
/// dirs (removed in `defer`). NEVER the real network and NEVER the real `~/.local/bin` (D7). Asserts
/// the success path (binary replaced + reseed called once with the stamped tag), checksum mismatch →
/// abort with binary + VERSION untouched, download failure, asset-resolution failure, the atomic
/// same-dir move's untouched-on-failure invariant, and the already-up-to-date no-op.
struct UpdateApplyTests {

    // MARK: - Fixtures / helpers

    /// A fresh UUID-named temp dir (created lazily by the flow / the test).
    private func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-sdd-apply-\(UUID().uuidString)", isDirectory: true)
    }

    private func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }

    /// A real lowercase-hex sha256 of `bytes` via the engine default checksum.
    private func sha256(_ bytes: Data) -> String { UpdateApply.defaultChecksum(bytes) }

    private let tarballURL = URL(string: "https://example.com/ai-sdd-macos-universal.tar.gz")!
    private let checksumURL = URL(string: "https://example.com/ai-sdd-macos-universal.tar.gz.sha256")!

    /// A resolver returning fixed assets at the given tag.
    private func resolver(tag: String) -> UpdateCheck.AssetResolver {
        { _ in UpdateCheck.ResolvedAssets(tag: tag, tarballURL: self.tarballURL, checksumURL: self.checksumURL) }
    }

    /// A recording reseed hook.
    private final class RecordingReseeder: @unchecked Sendable {
        private(set) var calls: [String] = []
        func hook() -> UpdateApply.Reseeder { { v in self.calls.append(v) } }
    }

    /// A `@Sendable`-safe mutable boolean a fake seam can flip (Sendable closures can't capture a
    /// mutable `var`).
    private final class Flag: @unchecked Sendable {
        private(set) var value = false
        func set() { value = true }
    }

    /// A recording extractor that writes `binaryBytes` as the unpacked `ai-sdd` binary into destDir.
    private func extractor(binaryBytes: Data) -> UpdateApply.Extractor {
        { _, destDir in
            let out = destDir.appendingPathComponent(Layout.updateInstallBinaryName)
            try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            try? binaryBytes.write(to: out)
            return out
        }
    }

    /// The default real-ish mover (same-dir temp-write-then-rename) the engine ships.
    private var mover: UpdateApply.Mover { UpdateApply.fileSystemMover }

    // MARK: - resolve-assets

    @Test func resolveAssetsFromFixturePayload() throws {
        let payload: [String: Any] = [
            "tag_name": "v0.6.0",
            "assets": [
                ["name": Layout.updateAssetName,
                 "browser_download_url": "https://example.com/ai-sdd-macos-universal.tar.gz"],
                ["name": Layout.updateAssetChecksumName,
                 "browser_download_url": "https://example.com/ai-sdd-macos-universal.tar.gz.sha256"]
            ]
        ]
        let resolved = try #require(UpdateCheck.resolveAssets(from: payload))
        #expect(resolved.tag == "v0.6.0")
        #expect(resolved.tarballURL.absoluteString == "https://example.com/ai-sdd-macos-universal.tar.gz")
        #expect(resolved.checksumURL.absoluteString == "https://example.com/ai-sdd-macos-universal.tar.gz.sha256")
    }

    @Test func resolveAssetsMissingSidecarYieldsNil() {
        let payload: [String: Any] = [
            "tag_name": "v0.6.0",
            "assets": [
                ["name": Layout.updateAssetName,
                 "browser_download_url": "https://example.com/ai-sdd-macos-universal.tar.gz"]
            ]
        ]
        #expect(UpdateCheck.resolveAssets(from: payload) == nil)
    }

    @Test func resolveAssetsMissingTagYieldsNil() {
        let payload: [String: Any] = ["assets": []]
        #expect(UpdateCheck.resolveAssets(from: payload) == nil)
    }

    @Test func assetResolutionFailureSurfacesTypedError() {
        let work = makeTempDir(); defer { remove(work) }
        let install = makeTempDir().appendingPathComponent("ai-sdd")
        let reseeder = RecordingReseeder()
        #expect(throws: UpdateApply.ApplyError.assetResolutionFailed) {
            _ = try UpdateApply.apply(
                runningVersion: "0.5.0",
                installPath: install,
                workDir: work,
                resolver: { _ in nil },
                downloader: { _ in nil },
                extractor: { _, _ in nil },
                mover: self.mover,
                reseed: reseeder.hook())
        }
        #expect(reseeder.calls.isEmpty)
    }

    // MARK: - checksum-verify-pass (success path)

    @Test func successPathReplacesBinaryAndReseedsOnce() throws {
        let work = makeTempDir(); defer { remove(work) }
        let installDir = makeTempDir(); defer { remove(installDir) }
        let install = installDir.appendingPathComponent("ai-sdd")
        try FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true)
        try Data("OLD-BINARY".utf8).write(to: install)

        let newBinary = Data("NEW-BINARY-v0.6.0".utf8)
        let tarballBytes = Data("fake-tarball-bytes".utf8)
        let goodChecksum = Data("\(sha256(tarballBytes))  \(Layout.updateAssetName)".utf8)
        let reseeder = RecordingReseeder()

        let downloader: UpdateApply.Downloader = { url in
            url == self.tarballURL ? tarballBytes : goodChecksum
        }

        let outcome = try UpdateApply.apply(
            runningVersion: "0.5.0",
            installPath: install,
            workDir: work,
            resolver: resolver(tag: "v0.6.0"),
            downloader: downloader,
            extractor: extractor(binaryBytes: newBinary),
            mover: mover,
            reseed: reseeder.hook())

        #expect(outcome == .applied(from: "0.5.0", to: "0.6.0"))
        let installed = try Data(contentsOf: install)
        #expect(installed == newBinary)
        #expect(reseeder.calls == ["0.6.0"])
    }

    // MARK: - version-stamp-after-replace

    @Test func reseedReceivesStampedTagForm() throws {
        let work = makeTempDir(); defer { remove(work) }
        let installDir = makeTempDir(); defer { remove(installDir) }
        let install = installDir.appendingPathComponent("ai-sdd")
        try FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true)
        try Data("OLD".utf8).write(to: install)

        let tarballBytes = Data("tarball".utf8)
        let goodChecksum = Data(sha256(tarballBytes).utf8)
        let reseeder = RecordingReseeder()

        _ = try UpdateApply.apply(
            runningVersion: "1.2.3",
            installPath: install,
            workDir: work,
            resolver: resolver(tag: "v2.0.0"),
            downloader: { url in url == self.tarballURL ? tarballBytes : goodChecksum },
            extractor: extractor(binaryBytes: Data("new".utf8)),
            mover: mover,
            reseed: reseeder.hook())

        // The resolved tag `v2.0.0` is stamped as `2.0.0` (leading-v stripped).
        #expect(reseeder.calls == ["2.0.0"])
    }

    // MARK: - checksum-mismatch-aborts

    @Test func checksumMismatchAbortsBinaryUntouched() throws {
        let work = makeTempDir(); defer { remove(work) }
        let installDir = makeTempDir(); defer { remove(installDir) }
        let install = installDir.appendingPathComponent("ai-sdd")
        try FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true)
        let originalBytes = Data("ORIGINAL-BINARY".utf8)
        try originalBytes.write(to: install)

        let tarballBytes = Data("tarball-bytes".utf8)
        // A deliberately wrong (but well-formed) 64-hex sidecar.
        let wrong = String(repeating: "a", count: 64)
        let badChecksum = Data(wrong.utf8)
        let reseeder = RecordingReseeder()

        let extractorCalled = Flag()
        let countingExtractor: UpdateApply.Extractor = { _, _ in extractorCalled.set(); return nil }

        #expect(throws: UpdateApply.ApplyError.checksumMismatch(expected: wrong, actual: sha256(tarballBytes))) {
            _ = try UpdateApply.apply(
                runningVersion: "0.5.0",
                installPath: install,
                workDir: work,
                resolver: resolver(tag: "v0.6.0"),
                downloader: { url in url == self.tarballURL ? tarballBytes : badChecksum },
                extractor: countingExtractor,
                mover: self.mover,
                reseed: reseeder.hook())
        }

        // Aborted BEFORE extract/move: binary byte-for-byte unchanged, no extract, no reseed.
        #expect(try Data(contentsOf: install) == originalBytes)
        #expect(extractorCalled.value == false)
        #expect(reseeder.calls.isEmpty)
    }

    // MARK: - download-failure-aborts

    @Test func tarballDownloadFailureAbortsUntouched() throws {
        let work = makeTempDir(); defer { remove(work) }
        let installDir = makeTempDir(); defer { remove(installDir) }
        let install = installDir.appendingPathComponent("ai-sdd")
        try FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true)
        let originalBytes = Data("ORIGINAL".utf8)
        try originalBytes.write(to: install)
        let reseeder = RecordingReseeder()

        #expect(throws: UpdateApply.ApplyError.downloadFailed(which: "tarball")) {
            _ = try UpdateApply.apply(
                runningVersion: "0.5.0",
                installPath: install,
                workDir: work,
                resolver: resolver(tag: "v0.6.0"),
                downloader: { _ in nil },
                extractor: extractor(binaryBytes: Data("new".utf8)),
                mover: self.mover,
                reseed: reseeder.hook())
        }
        #expect(try Data(contentsOf: install) == originalBytes)
        #expect(reseeder.calls.isEmpty)
    }

    @Test func sidecarDownloadFailureAborts() throws {
        let work = makeTempDir(); defer { remove(work) }
        let install = makeTempDir().appendingPathComponent("ai-sdd")
        let reseeder = RecordingReseeder()
        #expect(throws: UpdateApply.ApplyError.downloadFailed(which: "checksum")) {
            _ = try UpdateApply.apply(
                runningVersion: "0.5.0",
                installPath: install,
                workDir: work,
                resolver: resolver(tag: "v0.6.0"),
                downloader: { url in url == self.tarballURL ? Data("t".utf8) : nil },
                extractor: extractor(binaryBytes: Data("new".utf8)),
                mover: self.mover,
                reseed: reseeder.hook())
        }
        #expect(reseeder.calls.isEmpty)
    }

    // MARK: - atomic-replace-same-dir (move-seam failure leaves target intact)

    @Test func moveFailureLeavesOriginalIntact() throws {
        let work = makeTempDir(); defer { remove(work) }
        let installDir = makeTempDir(); defer { remove(installDir) }
        let install = installDir.appendingPathComponent("ai-sdd")
        try FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true)
        let originalBytes = Data("ORIGINAL-INTACT".utf8)
        try originalBytes.write(to: install)

        let tarballBytes = Data("tarball".utf8)
        let goodChecksum = Data(sha256(tarballBytes).utf8)
        let reseeder = RecordingReseeder()
        let failingMover: UpdateApply.Mover = { _, _ in throw UpdateApply.ApplyError.moveFailed }

        #expect(throws: UpdateApply.ApplyError.moveFailed) {
            _ = try UpdateApply.apply(
                runningVersion: "0.5.0",
                installPath: install,
                workDir: work,
                resolver: resolver(tag: "v0.6.0"),
                downloader: { url in url == self.tarballURL ? tarballBytes : goodChecksum },
                extractor: extractor(binaryBytes: Data("new".utf8)),
                mover: failingMover,
                reseed: reseeder.hook())
        }
        // Move never committed → original bytes preserved, no reseed.
        #expect(try Data(contentsOf: install) == originalBytes)
        #expect(reseeder.calls.isEmpty)
    }

    // MARK: - already-up-to-date-noop

    @Test func alreadyUpToDateIsNoOp() throws {
        let work = makeTempDir(); defer { remove(work) }
        let install = makeTempDir().appendingPathComponent("ai-sdd")
        let reseeder = RecordingReseeder()
        let downloaderCalled = Flag()

        let outcome = try UpdateApply.apply(
            runningVersion: "0.6.0",
            installPath: install,
            workDir: work,
            resolver: resolver(tag: "v0.6.0"),
            downloader: { _ in downloaderCalled.set(); return nil },
            extractor: { _, _ in nil },
            mover: mover,
            reseed: reseeder.hook())

        #expect(outcome == .alreadyUpToDate(running: "0.6.0", latestTag: "v0.6.0"))
        #expect(downloaderCalled.value == false)
        #expect(reseeder.calls.isEmpty)
        #expect(FileManager.default.fileExists(atPath: install.path) == false)
    }

    @Test func devRunningVersionFailsClosed() {
        let work = makeTempDir(); defer { remove(work) }
        let install = makeTempDir().appendingPathComponent("ai-sdd")
        #expect(throws: UpdateApply.ApplyError.runningVersionUnparseable("0.0.0-unknown")) {
            _ = try UpdateApply.apply(
                runningVersion: "0.0.0-unknown",
                installPath: install,
                workDir: work,
                resolver: resolver(tag: "v9.9.9"),
                downloader: { _ in nil },
                extractor: { _, _ in nil },
                mover: self.mover,
                reseed: { _ in })
        }
    }

    // MARK: - sha256 sidecar parsing

    @Test func parseSha256AcceptsShasumFormatAndBareDigest() {
        let digest = String(repeating: "b", count: 64)
        #expect(UpdateApply.parseSha256(Data("\(digest)  file.tar.gz".utf8)) == digest)
        #expect(UpdateApply.parseSha256(Data(digest.utf8)) == digest)
        #expect(UpdateApply.parseSha256(Data("not-a-digest".utf8)) == nil)
    }
}
