import Foundation
import Yams

/// The cross-artifact coverage gate: every acceptance item the plan declares must be judged by the
/// review (review item ids ⊇ plan acceptance ids). Pure functions (parsing + set arithmetic) so
/// they're testable without files; the CLI reads the two artifacts and feeds their text in. This is
/// what stops a reviewer from silently skipping an acceptance item — the verdict gate only checks the
/// items that *are* present, so a missing item would otherwise pass unnoticed.
public enum CoverageChecker {
    /// The acceptance item ids a plan declares (its `acceptance[].id` list).
    public static func acceptanceIDs(planYAML: String) throws -> [String] {
        try ids(in: planYAML, list: "acceptance")
    }

    /// The acceptance ids a review judged (its `items[].id` list).
    public static func reviewedIDs(reviewYAML: String) throws -> [String] {
        try ids(in: reviewYAML, list: "items")
    }

    /// Acceptance ids the review left unjudged (empty == fully covered), in plan order.
    public static func uncovered(acceptance: [String], reviewed: [String]) -> [String] {
        let judged = Set(reviewed)
        return acceptance.filter { !judged.contains($0) }
    }

    /// Read `<list>[].id` from a structured artifact, skipping entries without a string id.
    private static func ids(in yaml: String, list: String) throws -> [String] {
        let object = try Yams.load(yaml: yaml) as? [String: Any]
        let items = (object?[list] as? [Any]) ?? []
        return items.compactMap { ($0 as? [String: Any])?["id"] as? String }
    }
}
