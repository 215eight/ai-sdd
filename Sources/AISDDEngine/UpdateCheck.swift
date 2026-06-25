import Foundation

/// The detect half of self-update (the apply path is a later slice). `UpdateCheck` is a pure
/// `AISDDEngine` helper — a `public enum` of statics with no stored state, shaped like
/// `Seeder` / `SkillSurface` / `Drift`: every effect (network, clock, cache I/O, the running version,
/// the stamp path) is *injected*, so the engine never calls `Date()`, never reaches the real
/// `~/.cache`, never imports the gitignored CLI build product, and is exercised entirely over fakes.
///
/// It resolves the latest published release tag of the public repo `215eight/ai-sdd` via the anonymous
/// GitHub `releases/latest` API, compares it to the running binary version (`SemanticVersion`), and
/// renders at most one "behind" notice plus the DC5 drift advisory. Everything is **fail-soft**: any
/// network / parse / cache / stamp failure collapses to a non-blocking outcome (`verdict == .unknown`
/// / no advisory) and never throws out of the check, so the command always exits 0.
public enum UpdateCheck {

    // MARK: - Verdict

    /// The typed outcome of comparing the running version to the resolved latest release.
    public enum Verdict: Equatable, Sendable {
        /// The latest release is newer than the running binary — emit the behind-notice.
        case behind(latestTag: String)
        /// The running binary is at (or ahead of) the latest release — emit nothing.
        case upToDate
        /// The check could not resolve a comparable verdict (offline, non-200, malformed JSON,
        /// unparseable tag, or a dev/unparseable running version) — fail-soft, emit nothing.
        case unknown
    }

    // MARK: - Injected seams

    /// The network seam: resolve the latest release tag from `url`, returning the tag string on
    /// success or `nil` on ANY failure (fail-soft). Mirrors `CheckRunner.execute`'s injected closure.
    /// The default (`urlSession`) performs a synchronous anonymous GET and parses `tag_name`; tests
    /// inject a closure that returns a fixed tag (or `nil`) and counts invocations.
    public typealias ReleaseFetcher = @Sendable (_ url: URL) -> String?

    /// The clock seam — a `@Sendable () -> Date` closure (default `{ Date() }`, bound by the CLI) so
    /// the engine never calls `Date()` directly (per the swift conventions, mirroring the
    /// single-wall-clock-boundary pattern in `GraphRenderer` / dashboards).
    public typealias Clock = @Sendable () -> Date

    // MARK: - Cache record

    /// The small JSON object persisted at `~/.cache/ai-sdd/last-check`: the last fetch timestamp and
    /// the resolved latest version string. A second check within the staleness window reads this and
    /// SKIPS the network. A corrupt / unreadable / missing file is treated as a cache miss (fail-soft).
    struct CacheRecord: Codable, Equatable {
        let checkedAt: Date
        let latestTag: String
    }

    // MARK: - Default fetcher

    /// The default `ReleaseFetcher`: a synchronous anonymous GET of the `releases/latest` endpoint,
    /// parsing `tag_name`. No auth token is sent. Every error (launch, non-200, empty body, malformed
    /// JSON, missing field) collapses to `nil`.
    public static let urlSession: ReleaseFetcher = { url in
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(Layout.updateUserAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 5

        // Bridge the async URLSession API to a synchronous closure (the engine seam is sync, like
        // CheckRunner.shell). A semaphore is safe here: this runs off the main actor in the CLI. The
        // completion-handler result is carried out through a small Sendable box, not captured vars.
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

        guard let payload = box.payload,
              let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let tag = obj["tag_name"] as? String, !tag.isEmpty else { return nil }
        return tag
    }

    // MARK: - The check

    /// Resolve the update verdict, reading the network only on a cache miss/stale entry.
    ///
    /// Flow (all steps fail-soft):
    ///   1. If the running version is a dev/non-release or unparseable string → `.unknown` (a dev
    ///      build is never nudged), no fetch, no cache write.
    ///   2. Else read the cache: if it exists and `(now - checkedAt) < stalenessWindow`, use its
    ///      `latestTag` as the verdict source and SKIP the network.
    ///   3. On a cache miss/stale/corrupt entry, fetch via `fetcher`; on success persist
    ///      `{ now, tag }` to the cache and use the fetched tag. A fetch failure → `.unknown`.
    ///   4. Compare the parsed latest release to the running version: strictly newer → `.behind`,
    ///      else `.upToDate`. An unparseable tag → `.unknown`.
    ///
    /// - Parameters:
    ///   - runningVersion: the injected `AISDDVersion.current` string (the CLI binds it).
    ///   - now: the injected clock value.
    ///   - cacheFile: the injected cache file URL (default resolves under the user home via Layout).
    ///   - fetcher: the injected network seam (default `urlSession`).
    public static func check(
        runningVersion: String,
        now: Date,
        cacheFile: URL,
        fetcher: ReleaseFetcher = urlSession
    ) -> Verdict {
        // (1) A dev/non-release or unparseable running version is never nudged.
        guard let running = SemanticVersion(runningVersion), running.isRelease else {
            return .unknown
        }

        // (2) Cache hit within the staleness window → reuse the cached tag, skip the network.
        let latestTag: String
        if let cached = readCache(at: cacheFile),
           now.timeIntervalSince(cached.checkedAt) < Layout.updateStalenessWindow,
           now.timeIntervalSince(cached.checkedAt) >= 0 {
            latestTag = cached.latestTag
        } else {
            // (3) Cache miss/stale → fetch; persist on success. A fetch failure is fail-soft.
            guard let fetched = fetcher(Layout.latestReleaseURL) else { return .unknown }
            writeCache(CacheRecord(checkedAt: now, latestTag: fetched), to: cacheFile)
            latestTag = fetched
        }

        // (4) Compare. An unparseable tag is fail-soft.
        return verdict(running: running, latestTag: latestTag)
    }

    /// Compare a parsed running release to a latest tag string. Strictly newer latest → `.behind`;
    /// equal/older → `.upToDate`; unparseable tag → `.unknown`.
    static func verdict(running: SemanticVersion, latestTag: String) -> Verdict {
        guard let latest = SemanticVersion(latestTag) else { return .unknown }
        return latest > running ? .behind(latestTag: latestTag) : .upToDate
    }

    // MARK: - Drift advisory (DC5)

    /// Whether the running binary is strictly NEWER than the seeded `.ai-sdd/VERSION` stamp — the DC5
    /// soft reseed advisory. Reads the stamp fail-soft (absent/unreadable → no advisory). Equal
    /// versions, a missing/unparseable stamp, or a dev binary all yield `false`.
    ///
    /// - Parameters:
    ///   - runningVersion: the injected `AISDDVersion.current` string.
    ///   - stampFile: the injected `.ai-sdd/VERSION` URL (the CLI resolves it under the workspace).
    public static func binaryNewerThanStamp(runningVersion: String, stampFile: URL) -> Bool {
        guard let running = SemanticVersion(runningVersion), running.isRelease,
              let text = try? String(contentsOf: stampFile, encoding: .utf8),
              let stamp = SemanticVersion(text) else { return false }
        return running > stamp
    }

    // MARK: - Cache I/O (fail-soft)

    /// Read the cache record at `url`, or `nil` on a missing / unreadable / corrupt file.
    static func readCache(at url: URL) -> CacheRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CacheRecord.self, from: data)
    }

    /// Write `record` to `url`, creating the parent dir. Any failure is swallowed (fail-soft).
    static func writeCache(_ record: CacheRecord, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(record) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url)
    }
}

/// `UpdateBanner` turns a cached verdict (+ the DC5 drift state) into zero-or-more notice lines. It is
/// a pure renderer — the CLI call site reads the cached verdict (never fetching) and routes these
/// lines to `FileHandle.standardError`, never stdout, so `ai-sdd next --json` keeps a clean stdout.
/// Both the behind-notice and the reseed advisory flow through this single helper (D5).
public enum UpdateBanner {
    /// Render the banner lines for a verdict and drift state. Returns `[]` (silent) for `.upToDate` /
    /// `.unknown` with no drift. At most one behind-notice line and one drift-advisory line.
    public static func lines(verdict: UpdateCheck.Verdict, binaryNewerThanStamp: Bool) -> [String] {
        var out: [String] = []
        if case let .behind(latestTag) = verdict {
            out.append("⬆ ai-sdd \(latestTag) is available (you're on an older build) — run /ai-sdd-update")
        }
        if binaryNewerThanStamp {
            out.append("⚠ your ai-sdd binary is newer than .ai-sdd/VERSION — run `ai-sdd seed` to reseed")
        }
        return out
    }
}
