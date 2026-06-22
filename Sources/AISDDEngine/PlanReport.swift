import Foundation

/// Pure render + exit-code decision for the `ai-sdd plan` command (ADR-0030). Takes an already
/// classified `ChangePlan` plus a `--require-ack` `Tier` threshold and returns the rendered, tier
/// grouped text together with whether an ack is required (the command's exit-code 2 signal). Reads
/// only the in-memory `ChangeClassification` values — no re-classification, no content reads, no
/// loader — so the command's behavior is unit-testable without driving `ParsableCommand` exit paths
/// (parent D1).
public enum PlanReport {
    /// The render + decision result. `renderedText` is the tier-grouped report (or `"no changes"`),
    /// `ackRequired` drives the command's `ExitCode(2)`.
    public struct Result: Equatable, Sendable {
        public var renderedText: String
        public var ackRequired: Bool

        public init(renderedText: String, ackRequired: Bool) {
            self.renderedText = renderedText
            self.ackRequired = ackRequired
        }
    }

    /// Map a classified `plan` + a `requireAck` threshold to `(renderedText, ackRequired)`.
    ///
    /// `ackRequired` is true when any change's tier meets-or-exceeds `requireAck`, with the parent D3
    /// carve-out: a `nonAckBlocking` change (an added 0-consumer contract) does not by itself trip the
    /// threshold when `requireAck == .contract` (the default) — it only counts when the threshold is
    /// lowered below `contract` so the change is "reached".
    public static func make(plan: ChangePlan, requireAck: Tier) -> Result {
        Result(renderedText: render(plan), ackRequired: ackRequired(plan, threshold: requireAck))
    }

    // MARK: - Decision

    private static func ackRequired(_ plan: ChangePlan, threshold: Tier) -> Bool {
        plan.classifications.contains { trips($0, threshold: threshold) }
    }

    /// Whether a single change reaches the ack threshold. Its tier must be `>=` the threshold; a
    /// `nonAckBlocking` change is exempt at the default `contract` threshold (parent D3) and only
    /// trips when the threshold is lowered below `contract`.
    private static func trips(_ change: ChangeClassification, threshold: Tier) -> Bool {
        guard change.tier >= threshold else { return false }
        if change.flags.contains(.nonAckBlocking) && threshold == .contract { return false }
        return true
    }

    // MARK: - Render

    /// The fixed group order: contract -> local -> refresh (parent D5). Empty groups are omitted.
    private static let groupOrder: [Tier] = [.contract, .local, .refresh]

    private static func heading(_ tier: Tier) -> String {
        switch tier {
        case .contract: return "contract"
        case .local:    return "local"
        case .refresh:  return "refresh"
        // `frozen` is not in `groupOrder` yet, so this arm is unreachable in this slice; it exists
        // only to keep the switch exhaustive after the `Tier.frozen` case was added. The frozen
        // grouping / hard-✗ rendering is the `cli-locks` slice (ADR-0031, D-SCOPE-ENGINE-ONLY).
        case .frozen:   return "frozen"
        }
    }

    private static func render(_ plan: ChangePlan) -> String {
        guard !plan.classifications.isEmpty else { return "no changes" }

        var lines: [String] = []
        for tier in groupOrder {
            let group = plan.classifications.filter { $0.tier == tier }
            guard !group.isEmpty else { continue }
            lines.append("\(heading(tier)):")
            for change in group {
                lines.append(contentsOf: render(change))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// One change: a `path (status)` line plus any inline flag/blast-radius label, and — for contract
    /// items — each consuming worker as `node (worker)`.
    private static func render(_ change: ChangeClassification) -> [String] {
        var head = "  \(change.path) (\(change.status.rawValue))"

        var labels: [String] = []
        if let blastRadius = change.blastRadius { labels.append(blastRadius) }
        for flag in change.flags { labels.append(flag.rawValue) }
        if !labels.isEmpty { head += " [\(labels.joined(separator: ", "))]" }

        var lines = [head]
        if change.tier == .contract {
            if change.consumers.isEmpty {
                lines.append("    consumers: none")
            } else {
                for consumer in change.consumers {
                    lines.append("    consumer: \(consumer.node) (\(consumer.worker))")
                }
            }
        }
        return lines
    }
}
