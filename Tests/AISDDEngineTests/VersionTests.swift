import Testing
import Foundation
@testable import AISDDEngine

/// Covers the pure `SemanticVersion` helper (ADR version-nudge prerequisites): semver ordering,
/// leading-`v` tolerance, dev/non-release detection, and fail-closed parsing of malformed input.
struct VersionTests {
    @Test func semverOrdering() throws {
        let older = try #require(SemanticVersion("0.5.0"))
        let newer = try #require(SemanticVersion("0.6.0"))
        #expect(newer > older)
        #expect(older < newer)
        // Precedence walks major, then minor, then patch.
        #expect(try #require(SemanticVersion("1.0.0")) > newer)
        #expect(try #require(SemanticVersion("0.6.1")) > newer)
        #expect(SemanticVersion("0.6.0") == SemanticVersion("0.6.0"))
    }

    @Test func leadingVTolerated() throws {
        let withV = try #require(SemanticVersion("v0.6.0"))
        let withoutV = try #require(SemanticVersion("0.6.0"))
        #expect(withV == withoutV)
        #expect(withV.major == 0 && withV.minor == 6 && withV.patch == 0)
        #expect(withV.isRelease)
    }

    @Test func cleanReleaseIsRelease() throws {
        let release = try #require(SemanticVersion("0.6.0"))
        #expect(release.isRelease)
        #expect(!release.isDev)
        #expect(release.suffix == nil)
    }

    @Test func suffixedValueIsNonRelease() throws {
        // A pre-release, a build-metadata tail, and a `git describe` dirty tail are all non-release.
        for raw in ["0.6.0-dev", "0.6.0-rc.1", "0.6.0+build.7", "0.6.0-3-g76c6740-dirty"] {
            let version = try #require(SemanticVersion(raw), "expected \(raw) to parse")
            #expect(version.isDev, "\(raw) should be non-release")
            #expect(!version.isRelease)
            #expect(version.suffix != nil)
            // The core still orders by major.minor.patch, ignoring the suffix.
            #expect(version == SemanticVersion(major: 0, minor: 6, patch: 0, suffix: version.suffix))
        }
    }

    @Test func malformedFailsClosed() {
        // Each of these is "unknown" — parse returns nil, no crash. A bare describe SHA, the
        // tarball fallback's non-numeric head, partial versions, junk, and empties all fail closed.
        for raw in ["", "  ", "76c6740", "0.0.0-unknown".replacingOccurrences(of: "0.0.0", with: "unknown"),
                    "unknown", "1.2", "1", "1.2.3.4", "1.2.x", "v", "vv1.2.3", "1..3", "-1.2.3", "a.b.c"] {
            #expect(SemanticVersion(raw) == nil, "expected \(raw.debugDescription) to fail closed")
        }
    }

    @Test func tarballFallbackHeadParses() throws {
        // `0.0.0-unknown` (the gen-version.sh non-checkout fallback) has a valid `0.0.0` head with an
        // `unknown` suffix → it parses, but is correctly classified non-release.
        let fallback = try #require(SemanticVersion("0.0.0-unknown"))
        #expect(fallback.isDev)
        #expect(fallback.suffix == "unknown")
    }
}
