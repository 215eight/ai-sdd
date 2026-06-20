import Foundation
import Yams

public extension Rework {
    /// A routing hint read from a produced artifact: which input schemas a verdict indicts.
    struct RoutingHint: Equatable, Sendable {
        public var targets: [String]      // indicted input schemas (may be empty → escalate, nowhere to route)
        public init(targets: [String]) { self.targets = targets }
    }

    /// Read a rework-routing hint from a produced artifact. A hint is returned **only** when the
    /// artifact is a *verdict* artifact — it carries a `verdict` field or a `rework:` block — which
    /// is what marks its gate failure as indicting its inputs (route upstream) rather than itself.
    /// Returns nil otherwise (a changeset/plan whose gate failed self-reworks). No node/worker flag:
    /// the artifact's own shape drives the transition (specs are data; transitions follow inputs).
    static func routingHint(artifactYAML: String) throws -> RoutingHint? {
        guard let object = try Yams.load(yaml: artifactYAML) as? [String: Any] else { return nil }
        let entries = object["rework"] as? [Any]
        guard object["verdict"] != nil || entries != nil else { return nil }
        let targets = (entries ?? []).compactMap { ($0 as? [String: Any])?["target"] as? String }
        return RoutingHint(targets: targets)
    }
}
