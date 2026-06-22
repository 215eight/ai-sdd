import Foundation

/// Surfacing framework skills into each coding agent's native skill dir is a purely mechanical,
/// deterministic step (no judgment): for every framework skill under `.ai-sdd/skills/`, ensure a
/// symlink `<agent-dir>/<name> -> ../../.ai-sdd/skills/<name>` exists in every agent dir, fix any
/// that point elsewhere, and prune any that point at a framework skill that no longer exists. This
/// replaces the prose in the bootstrap skill (which drifted) with an idempotent, drift-checkable
/// command. The reconcile is a pure function (repo root + agent table + discovered skills → ops),
/// so it's unit-testable against a temp fixture and the apply step is a thin wrapper over `FileManager`.
public enum SkillSurface {
    /// One planned change to one symlink in one agent dir. `unchanged` is reported (so a run can
    /// show "already reconciled") but applies nothing.
    public enum Operation: String, Sendable, Equatable {
        case created    // the symlink was missing → create it
        case fixed      // the symlink existed but pointed elsewhere → repoint it
        case pruned     // a stale symlink into `.ai-sdd/skills/` whose skill is gone → remove it
        case unchanged  // already correct → leave it
    }

    /// A planned op against `<agentDir>/<name>`.
    public struct PlannedOp: Sendable, Equatable {
        public let agent: String
        public let agentDir: String  // repo-relative, e.g. ".claude/skills"
        public let name: String      // the skill (link) name
        public let op: Operation
        public init(agent: String, agentDir: String, name: String, op: Operation) {
            self.agent = agent
            self.agentDir = agentDir
            self.name = name
            self.op = op
        }
        /// Whether applying this op changes the tree (everything but `unchanged`).
        public var mutates: Bool { op != .unchanged }
    }

    /// The result of a `surface` invocation, grouped for reporting.
    public struct Result: Sendable {
        public let ops: [PlannedOp]
        public let applied: Bool  // false in --check mode
        /// True when nothing is out of sync (every op is `unchanged`).
        public var reconciled: Bool { !ops.contains { $0.mutates } }
        /// Ops for one agent dir, in stable (name) order.
        public func ops(forAgentDir dir: String) -> [PlannedOp] {
            ops.filter { $0.agentDir == dir }
        }
    }

    /// The agent dirs present in an op list, in the table's declared order (so the report mirrors
    /// the declarative table even if `plan` ever reorders).
    public static func agentDirsInOrder(_ ops: [PlannedOp]) -> [(agent: String, dir: String)] {
        Layout.agentSkillSurfaces.filter { surface in ops.contains { $0.agentDir == surface.dir } }
    }

    /// A one-glyph marker for an op, for the CLI report.
    public static func glyph(_ op: Operation) -> String {
        switch op {
        case .created:   return "+"
        case .fixed:     return "~"
        case .pruned:    return "-"
        case .unchanged: return "·"
        }
    }

    // MARK: - Discovery

    /// The framework skills under `<repoRoot>/.ai-sdd/skills`: subdirectories whose name starts with
    /// `ai-sdd-` AND contain a `SKILL.md`. Worker skills (`plan-feature`, …) lack the prefix and are
    /// excluded — they resolve by path, never symlinked. Returns the bare skill names, sorted.
    public static func frameworkSkills(repoRoot: URL) -> [String] {
        let source = repoRoot.appendingPathComponent(Layout.skillsSource, isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: source, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return entries.compactMap { entry -> String? in
            let name = entry.lastPathComponent
            guard name.hasPrefix(Layout.frameworkSkillPrefix),
                  (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  FileManager.default.fileExists(
                    atPath: entry.appendingPathComponent(Layout.skillManifestFile).path)
            else { return nil }
            return name
        }.sorted()
    }

    // MARK: - Planning (pure)

    /// Compute the planned ops for one repo, given the agent table and the discovered framework
    /// skills. Pure except for reading the current symlink targets (so it can decide create/fix/
    /// unchanged/prune); writes nothing. For each agent dir: every framework skill yields a
    /// create/fix/unchanged op; any existing symlink that points into `.ai-sdd/skills/` but whose
    /// skill is no longer a framework skill yields a `pruned` op. Regular files/dirs and symlinks
    /// pointing elsewhere are left untouched (no op).
    public static func plan(repoRoot: URL,
                            agents: [(agent: String, dir: String)]? = nil,
                            frameworkSkills: [String]) -> [PlannedOp] {
        let agents = agents ?? Layout.agentSkillSurfaces
        let skills = Set(frameworkSkills)
        var ops: [PlannedOp] = []
        let fm = FileManager.default

        for (agent, agentDir) in agents {
            let dirURL = repoRoot.appendingPathComponent(agentDir, isDirectory: true)

            // Desired links — one per framework skill, in sorted order.
            for name in frameworkSkills {
                let link = dirURL.appendingPathComponent(name)
                let wanted = Layout.skillSurfaceTarget(name)
                let current = (try? fm.destinationOfSymbolicLink(atPath: link.path))
                let op: Operation
                if current == nil {
                    op = .created          // missing (or not a symlink)
                } else if current == wanted {
                    op = .unchanged        // already correct
                } else {
                    op = .fixed            // points elsewhere → repoint
                }
                ops.append(PlannedOp(agent: agent, agentDir: agentDir, name: name, op: op))
            }

            // Prune — existing symlinks into `.ai-sdd/skills/` whose skill is no longer present.
            let entries = (try? fm.contentsOfDirectory(atPath: dirURL.path)) ?? []
            for name in entries.sorted() where !skills.contains(name) {
                let link = dirURL.appendingPathComponent(name)
                guard let target = try? fm.destinationOfSymbolicLink(atPath: link.path),
                      pointsIntoSkillsSource(target) else { continue }
                ops.append(PlannedOp(agent: agent, agentDir: agentDir, name: name, op: .pruned))
            }
        }
        return ops
    }

    /// Whether a symlink target resolves into `.ai-sdd/skills/` — i.e. it's a managed surface link
    /// (so a stale one is ours to prune). Matches the `../../.ai-sdd/skills/` relative shape any
    /// agent dir produces; tolerant of extra leading `./` segments.
    static func pointsIntoSkillsSource(_ target: String) -> Bool {
        target.contains("\(Layout.skillsSource)/") || target.hasSuffix(Layout.skillsSource)
    }

    // MARK: - Apply

    /// Reconcile the repo: discover framework skills, plan the ops, and (unless `check`) apply the
    /// mutating ones. In `check` mode nothing is written. Missing agent dirs are created (when
    /// applying) before their links are placed. Returns the full op list for reporting.
    @discardableResult
    public static func reconcile(repoRoot: URL,
                                 agents: [(agent: String, dir: String)]? = nil,
                                 check: Bool) throws -> Result {
        let agents = agents ?? Layout.agentSkillSurfaces
        let skills = frameworkSkills(repoRoot: repoRoot)
        let ops = plan(repoRoot: repoRoot, agents: agents, frameworkSkills: skills)
        guard !check else { return Result(ops: ops, applied: false) }

        let fm = FileManager.default
        for op in ops where op.mutates {
            let dirURL = repoRoot.appendingPathComponent(op.agentDir, isDirectory: true)
            let link = dirURL.appendingPathComponent(op.name)
            switch op.op {
            case .created, .fixed:
                try fm.createDirectory(at: dirURL, withIntermediateDirectories: true)
                // Replace any existing entry at the path (a wrong-target symlink), then link fresh.
                try? fm.removeItem(at: link)
                try fm.createSymbolicLink(atPath: link.path,
                                          withDestinationPath: Layout.skillSurfaceTarget(op.name))
            case .pruned:
                try fm.removeItem(at: link)
            case .unchanged:
                break
            }
        }
        return Result(ops: ops, applied: true)
    }
}
