import Foundation
import AISDDModels

/// Resolves a single `<name>` argument (passed to `next`, `submit`, or `status`) to a target run,
/// self-starting one when none exists yet. The single lookup path shared by all three verbs so a
/// feature slug, an existing runId, or a unique slice name behaves identically everywhere (S3).
///
/// The lookup is split into a PURE core (`resolve(name:inputs:)` over in-memory values) and an
/// I/O edge (`Inputs.live`) that injects filesystem/git access behind closures — mirroring
/// `RunStore`'s `gitToplevel` / `captureOwner` injection. The pure core is exercised across all
/// five branches in tests with no real `.ai-sdd` tree.
public enum RunResolver {

    /// The typed outcome of resolving a `<name>`. First match in precedence order wins:
    /// existing runId → feature dir → unique slice → ambiguous → unknown.
    public enum Resolution: Equatable, Sendable {
        /// `<name>` is an existing runId — use it as-is, no self-start.
        case existingRun(runId: String)
        /// A feature dir `.ai-sdd/features/<name>/` exists and no run does — self-start `runId=<name>`.
        case featureSelfStart(feature: String)
        /// `<name>` is a slice id in exactly one feature — self-start that feature's run (`runId=<feature>`).
        case sliceSelfStart(feature: String, slice: String)
        /// `<name>` is a slice id in more than one feature — `{"error":"ambiguous","candidates":[…]}`.
        case ambiguous(candidates: [String])
        /// `<name>` matches no runId, no feature dir, and no slice id — `{"error":"unknown"}`.
        case unknown

        /// The runId a resolution targets, or `nil` for the two error branches.
        public var runId: String? {
            switch self {
            case let .existingRun(runId):           return runId
            case let .featureSelfStart(feature):    return feature
            case let .sliceSelfStart(feature, _):   return feature
            case .ambiguous, .unknown:              return nil
            }
        }
    }

    /// The injected inputs the pure core reads — all filesystem/git access lives here so the core
    /// stays I/O-free and testable. `features` is the loaded slice topology: each feature paired with
    /// the node ids of its `pipeline.yaml` (its slice list).
    public struct Inputs: Sendable {
        /// Whether a run with this id already exists in the store.
        public var runExists: @Sendable (String) -> Bool
        /// Whether a feature dir `.ai-sdd/features/<name>/` exists.
        public var featureDirExists: @Sendable (String) -> Bool
        /// The slice topology: `(feature, sliceIds)` for each feature under `.ai-sdd/features/*`.
        public var features: @Sendable () -> [(feature: String, slices: [String])]

        public init(runExists: @escaping @Sendable (String) -> Bool,
                    featureDirExists: @escaping @Sendable (String) -> Bool,
                    features: @escaping @Sendable () -> [(feature: String, slices: [String])]) {
            self.runExists = runExists
            self.featureDirExists = featureDirExists
            self.features = features
        }
    }

    // MARK: - Pure core

    /// Resolve `name` to a `Resolution`, checking precedence strictly in order
    /// (decision `resolution-precedence-order`): (1) existing runId, (2) feature dir, (3) unique
    /// slice id across features, (4) ambiguous slice, (5) unknown. Pure — every input is injected.
    public static func resolve(name: String, inputs: Inputs) -> Resolution {
        // (1) An existing runId is used as-is, preserving today's behavior for callers passing a runId.
        if inputs.runExists(name) {
            return .existingRun(runId: name)
        }
        // (2) A feature dir self-starts `runId=<name>` — checked before slices so a feature whose name
        //     also appears as a slice elsewhere is not mis-resolved.
        if inputs.featureDirExists(name) {
            return .featureSelfStart(feature: name)
        }
        // (3)/(4) Slice id lookup across every feature's slice list.
        let owners = featuresOwning(slice: name, features: inputs.features()).sorted()
        switch owners.count {
        case 0:  return .unknown                                              // (5)
        case 1:  return .sliceSelfStart(feature: owners[0], slice: name)      // (3)
        default: return .ambiguous(candidates: owners)                       // (4)
        }
    }

    /// The features whose slice list contains `slice` — the pure slice→feature lookup
    /// (decision `slice-to-feature-via-pipeline-node-ids`). Deduplicated so a feature listing a slice
    /// twice counts once.
    public static func featuresOwning(slice: String,
                                      features: [(feature: String, slices: [String])]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for entry in features where entry.slices.contains(slice) {
            if seen.insert(entry.feature).inserted { result.append(entry.feature) }
        }
        return result
    }

    // MARK: - I/O edge

    /// The directory `.ai-sdd/features/<feature>/` holding a feature's `pipeline.yaml`, rooted at
    /// `workspace`. Owns the path literal in the engine (where `Layout.homeDir` is accessible) so the
    /// CLI's self-start reuses the same feature-dir construction as `liveInputs`.
    public static func featureDir(workspace: URL, feature: String) -> URL {
        workspace
            .appendingPathComponent(Layout.homeDir, isDirectory: true)
            .appendingPathComponent("features", isDirectory: true)
            .appendingPathComponent(feature, isDirectory: true)
    }

    /// Live inputs rooted at `workspace` (the dir holding `.ai-sdd/`), reusing `RunStore`,
    /// `SpecLoader`, and `Layout` — no second loader, no new persistence. A feature whose
    /// `pipeline.yaml` fails to load contributes no slices (it simply can't own a slice id).
    public static func liveInputs(workspace: URL, store: RunStore) -> Inputs {
        let featuresDir = workspace
            .appendingPathComponent(Layout.homeDir, isDirectory: true)
            .appendingPathComponent("features", isDirectory: true)
        return Inputs(
            runExists: { store.exists($0) },
            featureDirExists: { name in
                var isDir: ObjCBool = false
                let path = featureDir(workspace: workspace, feature: name).path
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
            },
            features: {
                let loader = SpecLoader()
                let entries = ((try? FileManager.default.contentsOfDirectory(
                    at: featuresDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                    .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                return entries.compactMap { entry in
                    guard let env = try? loader.loadPipeline(atDirectory: entry) else { return nil }
                    return (feature: entry.lastPathComponent, slices: env.spec.nodes.map(\.id))
                }
            })
    }
}
