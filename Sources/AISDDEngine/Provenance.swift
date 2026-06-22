import Foundation
import CryptoKit

/// One manifest entry recording how an artifact at a path was generated. `generatedAt` is always a
/// caller-supplied ISO-8601 string — the engine never reads the clock (ADR-0032 P1/P3). `contentHash`
/// is the lowercase-hex SHA-256 of the artifact bytes at record time.
public struct ProvenanceEntry: Codable, Equatable, Sendable {
    public var generator: String
    public var generatedAt: String
    public var contentHash: String

    public init(generator: String, generatedAt: String, contentHash: String) {
        self.generator = generator
        self.generatedAt = generatedAt
        self.contentHash = contentHash
    }
}

/// The classification of an artifact path against its recorded provenance: `pristine` (on-disk bytes
/// still hash to the recorded hash), `handEdited` (recorded but the bytes diverged), or `untracked`
/// (no recorded entry). Raw values match the slice/feature vocabulary.
public enum ProvenanceStatus: String, Equatable, Sendable {
    case pristine
    case handEdited = "hand-edited"
    case untracked
}

/// The clobber-guard decision for a generator about to (re-)write an artifact: a `handEdited` file
/// must not be overwritten; `pristine`/`untracked` are safe to write.
public enum ClobberDecision: String, Equatable, Sendable {
    case ok
    case doNotOverwrite = "do not overwrite"
}

/// A pure, injectable provenance manifest — a path-keyed map of `ProvenanceEntry`. Everything is
/// driven over `Data`/`URL`s so tests use temp files; the type holds no clock and reads no real
/// `.ai-sdd/`. Backed on disk by the committed `provenance.json` (deterministic, byte-stable JSON so
/// a no-op re-run yields no diff). Implements ADR-0032 decisions P1 and P3.
public struct Provenance: Equatable, Sendable {
    /// `path -> entry`. A path-keyed dictionary; `.sortedKeys` serialization stabilizes key + field order.
    public private(set) var entries: [String: ProvenanceEntry]

    public init(entries: [String: ProvenanceEntry] = [:]) {
        self.entries = entries
    }

    // MARK: - Hashing (pure)

    /// The lowercase-hex SHA-256 of `data`. Pure over the byte buffer (CryptoKit, ships with macOS 14).
    public static func contentHash(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Write API

    /// Record (or update) the entry for `path` from its bytes. `generatedAt` is a caller-supplied
    /// ISO-8601 string — never read from the clock. `contentHash` is computed from `data`.
    public mutating func record(path: String, generator: String, generatedAt: String, data: Data) {
        entries[path] = ProvenanceEntry(
            generator: generator,
            generatedAt: generatedAt,
            contentHash: Self.contentHash(of: data))
    }

    // MARK: - Read API

    /// Classify `path` by comparing the supplied current on-disk bytes to the recorded hash. No entry
    /// ⇒ `untracked`; hash match ⇒ `pristine`; hash mismatch ⇒ `handEdited`.
    public func status(of path: String, currentData: Data) -> ProvenanceStatus {
        guard let entry = entries[path] else { return .untracked }
        return entry.contentHash == Self.contentHash(of: currentData) ? .pristine : .handEdited
    }

    /// Classify `path` by reading its current bytes from `artifactURL`. A missing/unreadable file is
    /// treated as empty bytes (so a recorded-then-deleted artifact reads as `handEdited`).
    public func status(of path: String, artifactURL: URL) -> ProvenanceStatus {
        status(of: path, currentData: (try? Data(contentsOf: artifactURL)) ?? Data())
    }

    // MARK: - Clobber-guard (pure)

    /// Map a status to a clobber decision: `handEdited` ⇒ do not overwrite; `pristine`/`untracked` ⇒ ok.
    public static func clobberDecision(for status: ProvenanceStatus) -> ClobberDecision {
        status == .handEdited ? .doNotOverwrite : .ok
    }

    /// Whether the generator may overwrite an artifact in the given status.
    public static func canOverwrite(_ status: ProvenanceStatus) -> Bool {
        clobberDecision(for: status) == .ok
    }

    // MARK: - Load / save (injectable)

    /// The deterministic JSON encoder for the manifest: `.sortedKeys` gives stable path-key + field
    /// order, `.withoutEscapingSlashes` keeps `.ai-sdd/...` keys readable, so identical inputs ⇒
    /// byte-identical output (ADR-0032 D-DETERMINISTIC-JSON).
    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// Serialize the manifest to its deterministic, byte-stable JSON representation.
    public func encoded() throws -> Data {
        try Self.encoder().encode(entries)
    }

    /// Load a manifest from `url`. An absent file ⇒ an empty manifest (a fresh repo has no provenance).
    public static func load(from url: URL) throws -> Provenance {
        guard FileManager.default.fileExists(atPath: url.path) else { return Provenance() }
        let entries = try JSONDecoder().decode([String: ProvenanceEntry].self, from: Data(contentsOf: url))
        return Provenance(entries: entries)
    }

    /// Atomically write the deterministic manifest JSON to `url`.
    public func save(to url: URL) throws {
        try encoded().write(to: url, options: .atomic)
    }
}
