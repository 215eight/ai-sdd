import Testing
import Foundation
@testable import AISDDEngine

/// Covers the pure `UpdateCheck` / `UpdateBanner` helpers entirely over injected seams — a counting
/// fake fetcher, a fixed clock, and a UUID-named temp cache file (removed in `defer`). NEVER the real
/// network, real clock, or the real `~/.cache` directory (AC9). Verdict math, cache hit/miss, fetch
/// errors, the DC5 drift advisory, dev-build skip, and the banner's stderr-only line set are asserted.
struct UpdateCheckTests {

    /// A fresh UUID-named temp cache file URL under a temp dir (the dir is created lazily by writes).
    private func makeTempCacheURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-sdd-update-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(Layout.updateCacheFile)
    }

    /// A fetcher returning a fixed tag (or nil) that records how many times it was invoked.
    private final class CountingFetcher: @unchecked Sendable {
        private(set) var calls = 0
        let tag: String?
        init(returning tag: String?) { self.tag = tag }
        func fetcher() -> UpdateCheck.ReleaseFetcher {
            { _ in
                self.calls += 1
                return self.tag
            }
        }
    }

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - AC1 / AC2 / AC8: verdict math

    @Test("a newer latest release → behind notice (AC1)")
    func behindWhenLatestNewer() throws {
        let cache = makeTempCacheURL()
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        let fetcher = CountingFetcher(returning: "v0.6.0")
        let verdict = UpdateCheck.check(runningVersion: "0.5.0", now: t0,
                                        cacheFile: cache, fetcher: fetcher.fetcher())
        #expect(verdict == .behind(latestTag: "v0.6.0"))
        #expect(UpdateBanner.lines(verdict: verdict, binaryNewerThanStamp: false).count == 1)
    }

    @Test("an equal or older latest release → up to date, silent (AC2)")
    func upToDateWhenEqualOrOlder() throws {
        for tag in ["0.5.0", "v0.5.0", "0.4.9"] {
            let cache = makeTempCacheURL()
            defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
            let fetcher = CountingFetcher(returning: tag)
            let verdict = UpdateCheck.check(runningVersion: "0.5.0", now: t0,
                                            cacheFile: cache, fetcher: fetcher.fetcher())
            #expect(verdict == .upToDate, "expected up-to-date for latest \(tag)")
            #expect(UpdateBanner.lines(verdict: verdict, binaryNewerThanStamp: false).isEmpty)
        }
    }

    @Test("a dev / non-release / unparseable running version is never nudged (AC8)")
    func devBuildSkipsNudge() throws {
        for running in ["0.5.0-rc.1", "0.5.0+build.7", "3edc95c", "unknown", ""] {
            let cache = makeTempCacheURL()
            defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
            // A much-newer latest must NOT produce a behind-notice for a dev/unparseable running ver.
            let fetcher = CountingFetcher(returning: "v9.9.9")
            let verdict = UpdateCheck.check(runningVersion: running, now: t0,
                                            cacheFile: cache, fetcher: fetcher.fetcher())
            #expect(verdict == .unknown, "expected unknown for running \(running)")
            // No fetch is attempted for a dev/unparseable running version.
            #expect(fetcher.calls == 0)
            #expect(UpdateBanner.lines(verdict: verdict, binaryNewerThanStamp: false).isEmpty)
        }
    }

    // MARK: - AC3: fail-soft

    @Test("a fetch error (or unparseable tag) → unknown, silent (AC3)")
    func fetchErrorIsSilent() throws {
        let cache = makeTempCacheURL()
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        // nil fetch (offline / non-200 / malformed JSON all collapse to nil at the seam).
        let nilFetcher = CountingFetcher(returning: nil)
        #expect(UpdateCheck.check(runningVersion: "0.5.0", now: t0,
                                  cacheFile: cache, fetcher: nilFetcher.fetcher()) == .unknown)
        // An unparseable tag string is likewise fail-soft.
        let badTag = CountingFetcher(returning: "not-a-version")
        #expect(UpdateCheck.check(runningVersion: "0.5.0", now: t0,
                                  cacheFile: cache, fetcher: badTag.fetcher()) == .unknown)
    }

    // MARK: - AC4: cache hit suppresses the network

    @Test("a second check within the staleness window performs NO fetch (AC4)")
    func cacheHitSuppressesNetwork() throws {
        let cache = makeTempCacheURL()
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }

        // First check: cache miss → fetches once + writes the cache.
        let fetcher = CountingFetcher(returning: "v0.6.0")
        _ = UpdateCheck.check(runningVersion: "0.5.0", now: t0,
                              cacheFile: cache, fetcher: fetcher.fetcher())
        #expect(fetcher.calls == 1)
        #expect(FileManager.default.fileExists(atPath: cache.path))

        // Second check well within ~1 day: reuses the cached tag, fetcher NOT called again.
        let soon = t0.addingTimeInterval(60 * 60) // +1h
        let verdict = UpdateCheck.check(runningVersion: "0.5.0", now: soon,
                                        cacheFile: cache, fetcher: fetcher.fetcher())
        #expect(fetcher.calls == 1, "cache hit must not fetch")
        #expect(verdict == .behind(latestTag: "v0.6.0"))
    }

    // MARK: - AC5: cache miss fetches + writes; stale cache refetches

    @Test("a missing cache fetches once and persists timestamp + version (AC5)")
    func cacheMissFetchesAndWrites() throws {
        let cache = makeTempCacheURL()
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        let fetcher = CountingFetcher(returning: "v0.6.0")
        _ = UpdateCheck.check(runningVersion: "0.5.0", now: t0,
                              cacheFile: cache, fetcher: fetcher.fetcher())
        #expect(fetcher.calls == 1)

        let record = try #require(UpdateCheck.readCache(at: cache))
        #expect(record.latestTag == "v0.6.0")
        #expect(record.checkedAt == t0)
    }

    @Test("a stale cache (older than the window) refetches (AC5)")
    func staleCacheRefetches() throws {
        let cache = makeTempCacheURL()
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        // Seed a cache that is older than the staleness window.
        UpdateCheck.writeCache(.init(checkedAt: t0, latestTag: "v0.5.5"), to: cache)
        let fetcher = CountingFetcher(returning: "v0.6.0")
        let later = t0.addingTimeInterval(Layout.updateStalenessWindow + 1)
        let verdict = UpdateCheck.check(runningVersion: "0.5.0", now: later,
                                        cacheFile: cache, fetcher: fetcher.fetcher())
        #expect(fetcher.calls == 1, "a stale cache must refetch")
        #expect(verdict == .behind(latestTag: "v0.6.0"))
        // The cache is rewritten with the fresh timestamp + tag.
        let record = try #require(UpdateCheck.readCache(at: cache))
        #expect(record.checkedAt == later)
        #expect(record.latestTag == "v0.6.0")
    }

    @Test("a corrupt cache file is treated as a miss (fail-soft)")
    func corruptCacheIsMiss() throws {
        let cache = makeTempCacheURL()
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: cache)
        let fetcher = CountingFetcher(returning: "v0.6.0")
        let verdict = UpdateCheck.check(runningVersion: "0.5.0", now: t0,
                                        cacheFile: cache, fetcher: fetcher.fetcher())
        #expect(fetcher.calls == 1)
        #expect(verdict == .behind(latestTag: "v0.6.0"))
    }

    // MARK: - AC7: DC5 drift advisory

    @Test("binary strictly newer than the VERSION stamp → drift advisory (AC7)")
    func driftAdvisoryWhenBinaryNewer() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-sdd-stamp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stamp = dir.appendingPathComponent(Layout.versionStampFile)

        try Data("0.5.0".utf8).write(to: stamp)
        #expect(UpdateCheck.binaryNewerThanStamp(runningVersion: "0.6.0", stampFile: stamp))
        // Equal versions emit nothing for the advisory.
        #expect(!UpdateCheck.binaryNewerThanStamp(runningVersion: "0.5.0", stampFile: stamp))
        // A dev binary emits nothing.
        #expect(!UpdateCheck.binaryNewerThanStamp(runningVersion: "0.6.0-rc.1", stampFile: stamp))
        // The banner surfaces the advisory line independently of the update verdict.
        #expect(UpdateBanner.lines(verdict: .unknown, binaryNewerThanStamp: true).count == 1)
    }

    @Test("a missing or unparseable stamp yields no advisory (fail-soft)")
    func missingStampNoAdvisory() throws {
        let absent = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-sdd-missing-\(UUID().uuidString)")
        #expect(!UpdateCheck.binaryNewerThanStamp(runningVersion: "9.9.9", stampFile: absent))
    }

    // MARK: - AC6: banner line set (stdout/stderr separation contract)

    @Test("the banner renders both notices together and nothing when clean (AC6)")
    func bannerLineSet() {
        // Behind + drift → exactly two lines (the CLI routes them to stderr only).
        let both = UpdateBanner.lines(verdict: .behind(latestTag: "v0.6.0"), binaryNewerThanStamp: true)
        #expect(both.count == 2)
        // Up to date + no drift → silent.
        #expect(UpdateBanner.lines(verdict: .upToDate, binaryNewerThanStamp: false).isEmpty)
        #expect(UpdateBanner.lines(verdict: .unknown, binaryNewerThanStamp: false).isEmpty)
    }
}
