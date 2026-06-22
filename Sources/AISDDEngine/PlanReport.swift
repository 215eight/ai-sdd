import Foundation

/// Pure render + exit-code decision for the `ai-sdd plan` command (ADR-0030). Takes an already
/// classified `ChangePlan` plus a `--require-ack` `Tier` threshold and returns the rendered, tier
/// grouped text together with whether an ack is required (the command's exit-code 2 signal). Reads
/// only the in-memory `ChangeClassification` values — no re-classification, no content reads, no
/// loader — so the command's behavior is unit-testable without driving `ParsableCommand` exit paths
/// (parent D1).
public enum PlanReport {
    /// The render + decision result. `renderedText` is the tier-grouped report (or `"no changes"`),
    /// `ackRequired` drives the command's `ExitCode(2)`, and `frozenPresent` drives the command's
    /// `ExitCode(3)` — independent of `requireAck` and taking precedence over the ack check (ADR-0031).
    public struct Result: Equatable, Sendable {
        public var renderedText: String
        public var ackRequired: Bool
        /// True iff any classification is at the `frozen` tier (a locked path). Derived purely from
        /// the presence of a `.frozen` tier, so lowering `--require-ack` cannot change it.
        public var frozenPresent: Bool

        public init(renderedText: String, ackRequired: Bool, frozenPresent: Bool) {
            self.renderedText = renderedText
            self.ackRequired = ackRequired
            self.frozenPresent = frozenPresent
        }
    }

    /// Map a classified `plan` + a `requireAck` threshold to `(renderedText, ackRequired, frozenPresent)`.
    ///
    /// `ackRequired` is true when any change's tier meets-or-exceeds `requireAck`, with the parent D3
    /// carve-out: a `nonAckBlocking` change (an added 0-consumer contract) does not by itself trip the
    /// threshold when `requireAck == .contract` (the default) — it only counts when the threshold is
    /// lowered below `contract` so the change is "reached". `frozenPresent` is true iff any change is
    /// `frozen`, computed independently of the threshold.
    public static func make(plan: ChangePlan, requireAck: Tier) -> Result {
        make(classifications: plan.classifications, requireAck: requireAck)
    }

    /// Same as `make(plan:requireAck:)` but over a bare classification list — the seam the `--unlock`
    /// downgrade (see `downgradingUnlocked`) feeds, since it produces classifications rather than a
    /// `ChangePlan`. Reads only the in-memory values: no re-classification, no loader.
    public static func make(classifications: [ChangeClassification], requireAck: Tier) -> Result {
        Result(renderedText: render(classifications),
               ackRequired: ackRequired(classifications, threshold: requireAck),
               frozenPresent: frozenPresent(classifications))
    }

    // MARK: - `--unlock` downgrade (ADR-0031 D-UNLOCK-DOWNGRADE / D-UNLOCK-NOOP-L3)

    /// The outcome of applying `--unlock` paths to a classified plan: the (possibly) downgraded
    /// classification list, plus the `unlock` entries that matched no `frozen` change (the L3 no-op
    /// warning set, emitted to stderr by the CLI).
    public struct Downgrade: Equatable, Sendable {
        public var classifications: [ChangeClassification]
        public var unmatched: [String]

        public init(classifications: [ChangeClassification], unmatched: [String]) {
            self.classifications = classifications
            self.unmatched = unmatched
        }
    }

    /// Downgrade each `frozen` change whose path matches an `--unlock` entry back to its base tier for
    /// this invocation only — the `locks.yaml` manifest is never read for mutation or written. The base
    /// tier is recovered by re-running the existing base classification (a parallel `ChangePlan` over
    /// the same `changes` with `locks: []`), keeping a single classifier (no second source of truth).
    /// Path matching is exact-path equality against the change path. An `--unlock` entry that matches
    /// no `frozen` change is reported in `unmatched` (a no-op + warning, never an error — requirement
    /// L3). Operates entirely on in-memory classifications, so it is unit-testable in isolation.
    public static func downgradingUnlocked(
        plan: ChangePlan, changes: [ArtifactChange], homeDirectory: URL,
        unlock: [String], loader: SpecLoader = SpecLoader()) -> Downgrade {
        guard !unlock.isEmpty else { return Downgrade(classifications: plan.classifications, unmatched: []) }

        let unlockSet = Set(unlock)
        // The base classification (no locks) for the same changes — the single classifier, re-run.
        let baseByPath = Dictionary(
            ChangePlan(changes: changes, homeDirectory: homeDirectory, locks: [], loader: loader)
                .classifications.map { ($0.path, $0) },
            uniquingKeysWith: { first, _ in first })

        var matched: Set<String> = []
        let downgraded = plan.classifications.map { classification -> ChangeClassification in
            guard classification.tier == .frozen, unlockSet.contains(classification.path) else {
                return classification
            }
            matched.insert(classification.path)
            return baseByPath[classification.path] ?? classification
        }
        let unmatched = unlock.filter { !matched.contains($0) }
        return Downgrade(classifications: downgraded, unmatched: unmatched)
    }

    // MARK: - Decision

    private static func ackRequired(_ classifications: [ChangeClassification], threshold: Tier) -> Bool {
        classifications.contains { trips($0, threshold: threshold) }
    }

    /// Whether any change is at the `frozen` tier — the command's `ExitCode(3)` signal. Derived purely
    /// from the tier (like `ackRequired`), so it is independent of the `requireAck` threshold.
    private static func frozenPresent(_ classifications: [ChangeClassification]) -> Bool {
        classifications.contains { $0.tier == .frozen }
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

    /// The fixed group order: frozen -> contract -> local -> refresh (ADR-0031 D-FROZEN-GROUP-RENDER).
    /// `frozen` renders above `contract`. Empty groups are omitted.
    private static let groupOrder: [Tier] = [.frozen, .contract, .local, .refresh]

    private static func heading(_ tier: Tier) -> String {
        switch tier {
        case .frozen:   return "frozen"
        case .contract: return "contract"
        case .local:    return "local"
        case .refresh:  return "refresh"
        }
    }

    private static func render(_ classifications: [ChangeClassification]) -> String {
        guard !classifications.isEmpty else { return "no changes" }

        var lines: [String] = []
        for tier in groupOrder {
            let group = classifications.filter { $0.tier == tier }
            guard !group.isEmpty else { continue }
            lines.append("\(heading(tier)):")
            for change in group {
                lines.append(contentsOf: render(change))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// One change: a `path (status)` line plus any inline flag/blast-radius label, and — for contract
    /// items — each consuming worker as `node (worker)`. A `frozen` change renders as a hard ✗ line
    /// carrying its `lockReason` (ADR-0031 D-FROZEN-GROUP-RENDER), distinct from the other tiers.
    private static func render(_ change: ChangeClassification) -> [String] {
        if change.tier == .frozen {
            let reason = change.lockReason ?? "locked"
            return ["  ✗ \(change.path) (\(change.status.rawValue)) [frozen: \(reason)]"]
        }

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
