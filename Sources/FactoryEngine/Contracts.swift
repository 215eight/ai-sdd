import Foundation
import FactoryModels

/// Cross-references the `provides`/`requires` contracts declared across fragments and decides
/// version compatibility (ADR-0027). Git-native semver: a producer's `tag` (e.g. `v2.1.0`) versus a
/// consumer's caret `range` (e.g. `^2.0`). Pure — no I/O — so it is testable without a run.
public enum Contracts {
    /// One contract's standing across a program: who provides it (at what tag) and who consumes it.
    public struct Status: Equatable, Sendable {
        public var name: String
        public var provider: String?      // the fragment providing it (nil = no provider declared)
        public var providedTag: String?
        public var consumers: [Consumer]
    }

    public struct Consumer: Equatable, Sendable {
        public var fragment: String
        public var range: String
        public var satisfied: Bool?       // nil when the provider tag / range can't be compared
    }

    /// Build a status per contract (providers ∪ consumers), sorted by name. `fragments` pairs each
    /// fragment's display name with its metadata.
    public static func statuses(_ fragments: [(name: String, metadata: SpecMetadata)]) -> [Status] {
        var provider: [String: (fragment: String, tag: String?)] = [:]
        var consumers: [String: [(fragment: String, range: String)]] = [:]
        for (fragment, metadata) in fragments {
            for contract in metadata.provides ?? [] {
                provider[contract.name] = (fragment, contract.tag)
            }
            for contract in metadata.requires ?? [] {
                consumers[contract.name, default: []].append((fragment, contract.range ?? ""))
            }
        }
        let names = Set(provider.keys).union(consumers.keys).sorted()
        return names.map { name in
            let p = provider[name]
            let cs = (consumers[name] ?? []).map {
                Consumer(fragment: $0.fragment, range: $0.range,
                         satisfied: satisfies(providerTag: p?.tag, range: $0.range))
            }
            return Status(name: name, provider: p?.fragment, providedTag: p?.tag, consumers: cs)
        }
    }

    /// Does a provider `tag` satisfy a consumer caret `range`? Caret = same major and tag ≥ range.
    /// nil when either side is missing or unparseable (rendered as "unknown", not a pass).
    public static func satisfies(providerTag: String?, range: String) -> Bool? {
        guard let providerTag, let provider = SemVer(providerTag),
              let required = SemVer(range) else { return nil }
        return provider.major == required.major && provider >= required
    }
}

/// A minimal semver for compatibility checks. Accepts a leading `v`/`^`/`~` and partial versions
/// (`2`, `2.1`), padding missing parts with 0.
struct SemVer: Comparable {
    let major: Int, minor: Int, patch: Int

    init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "vV^~ "))
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard let first = parts.first, let major = first else { return nil }
        self.major = major
        self.minor = parts.count > 1 ? (parts[1] ?? 0) : 0
        self.patch = parts.count > 2 ? (parts[2] ?? 0) : 0
    }

    static func < (a: SemVer, b: SemVer) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }
}
