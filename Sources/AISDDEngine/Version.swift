import Foundation

/// A parsed semantic version (`major.minor.patch`) with an optional trailing suffix, used to reason
/// about the binary's `--version` value against a release tag. Pure and fail-closed: a value that
/// does not parse surfaces as `nil` from `init?`, never a crash or throw, so a caller (an
/// update-check / seed / drift slice) treats an unparseable or non-release string as "unknown — skip
/// the nudge" rather than acting on a malformed version.
///
/// This `AISDDEngine` type is intentionally distinct from the gitignored CLI build product
/// `Sources/AISDDCLI/Version.swift` (which only emits `enum AISDDVersion { static let current }`):
/// the engine owns the *reasoning* about a version string; the CLI file owns the *literal* value
/// `scripts/gen-version.sh` stamps in.
public struct SemanticVersion: Comparable, Equatable, Hashable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    /// The trailing suffix after `major.minor.patch`, if any — a pre-release (`-rc.1`), a build
    /// (`+sha`), or a `git describe` tail (`-3-g76c6740-dirty`). `nil` for a clean `X.Y.Z`. A
    /// non-`nil` suffix marks a non-release (`isDev`) value.
    public let suffix: String?

    public init(major: Int, minor: Int, patch: Int, suffix: String? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.suffix = suffix
    }

    /// Parse a `vX.Y.Z`/`X.Y.Z[-suffix]/[+suffix]` string, tolerating a single leading `v`. Fails
    /// closed (`nil`) on anything that is not three dot-separated non-negative integers in the
    /// `major.minor.patch` head — an empty string, a bare SHA (`76c6740`), `0.0.0-unknown`'s head is
    /// fine but a non-numeric head like `unknown` is not, a two-part `1.2`, or a negative/empty
    /// component. The caller treats a `nil` result as "unknown / non-release".
    public init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.first == "v" { text.removeFirst() }

        // Split off the first `-` or `+` delimited suffix; the head must be exactly `X.Y.Z`.
        let suffix: String?
        let head: Substring
        if let cut = text.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            head = text[text.startIndex..<cut]
            suffix = String(text[text.index(after: cut)...])
        } else {
            head = text[...]
            suffix = nil
        }

        let parts = head.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            // `Int(_:)` rejects empties, signs we don't want, and non-digits — fail closed.
            guard let value = Int(part), value >= 0,
                  part.allSatisfy({ $0.isNumber }) else { return nil }
            numbers.append(value)
        }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2],
                  suffix: (suffix?.isEmpty == true) ? nil : suffix)
    }

    /// A clean release: parsed cleanly AND carries no suffix. A pre-release / build / describe tail
    /// (anything that left a `suffix`) is NOT a release.
    public var isRelease: Bool { suffix == nil }

    /// The inverse of `isRelease` — a non-release/dev value (suffix present). An *unparseable* string
    /// never produces a `SemanticVersion`, so a caller maps "parse failed (`nil`) OR `isDev`" to
    /// "skip the update nudge".
    public var isDev: Bool { !isRelease }

    /// Semver precedence over `major.minor.patch` only (the suffix does not participate in ordering
    /// here — pre-release ranking is out of scope for the version-nudge use). Equal-core versions
    /// compare equal regardless of suffix; use `==` on the whole value for exact identity.
    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
