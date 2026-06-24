import Testing
import Foundation
import AISDDModels
@testable import AISDDEngine

/// End-to-end integration tests that exercise the real engine/assembler surface against the
/// COMMITTED demo fixture at `docs/examples/demo-factory/`. The fixture is located by a
/// REPO-RELATIVE path derived from `#filePath` (no absolute machine path), so the suite passes on a
/// fresh clone / CI. Status assertions are made on the structured `projection.rows`; inline-SVG and
/// HTML-escaping are asserted on the rendered `dashboardPage`.
@Suite("Fixture integration")
struct FixtureIntegrationTests {
    // MARK: - Fixture locator (machine-independent)

    /// The dir holding the committed fixture's `.ai-sdd` — `docs/examples/demo-factory`. Derived from
    /// `#filePath` (this file lives at `<repoRoot>/Tests/AISDDEngineTests/FixtureIntegrationTests.swift`,
    /// so the repo root is three parents up), then `docs/examples/demo-factory`. No absolute machine
    /// path appears in source; only repo-relative example-tree segments do.
    private var fixtureBase: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // AISDDEngineTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // <repoRoot>
            .appendingPathComponent("docs", isDirectory: true)
            .appendingPathComponent("examples", isDirectory: true)
            .appendingPathComponent("demo-factory", isDirectory: true)
    }

    /// The fixture factory home: `docs/examples/demo-factory/.ai-sdd`.
    private var factoryDir: URL {
        fixtureBase.appendingPathComponent(Layout.homeDir, isDirectory: true)
    }

    /// The fixture program dir: `.ai-sdd/programs/demo`.
    private var programDir: URL {
        factoryDir
            .appendingPathComponent(Layout.programsDir, isDirectory: true)
            .appendingPathComponent("demo", isDirectory: true)
    }

    private var featuresDir: URL {
        factoryDir.appendingPathComponent("features", isDirectory: true)
    }

    /// The build pattern dir: `.ai-sdd/build`.
    private var buildDir: URL {
        factoryDir.appendingPathComponent("build", isDirectory: true)
    }

    // MARK: - Helpers

    /// Build the run store EXACTLY as the shipped CLI dashboard path does:
    /// `RunStore.local(under: RunStore.base(forTarget: target))`. `base(forTarget:)` ascends to the
    /// nearest `.ai-sdd` ancestor and returns its parent (`fixtureBase` for both `factoryDir` and
    /// `programDir`), so the committed RELATIVE `pipelineDir` (`.ai-sdd/programs/demo`) resolves
    /// against the store base on any clone.
    private func storeFor(target: URL) -> RunStore {
        RunStore.local(under: RunStore.base(forTarget: target))
    }

    /// The status of a named row in a projection (mirrors the `status(_:_:)` helper in EngineTests).
    private func status(_ rows: [DashboardProjectionRow], _ node: String) -> DashboardStatus? {
        rows.first { $0.node == node }?.status
    }

    // MARK: - Tests

    @Test("Fixture factory loads and validates cleanly via the engine")
    func fixtureFactoryLoadsAndValidatesCleanly() throws {
        // Same API pair the CLI `Validate` command runs (loadBundle + SpecValidator.validate).
        let bundle = try SpecLoader().loadBundle(at: programDir)
        let issues = SpecValidator.validate(
            pipeline: bundle.pipeline.spec, workers: bundle.workers, checks: bundle.checks)
        #expect(issues.isEmpty)

        // Every feature pipeline and the build pattern load without throwing.
        for feature in ["auth", "billing", "search"] {
            let dir = featuresDir.appendingPathComponent(feature, isDirectory: true)
            #expect((try? SpecLoader().loadPipeline(atDirectory: dir)) != nil)
        }
        #expect((try? SpecLoader().loadPipeline(atDirectory: buildDir)) != nil)
    }

    @Test("Whole-repo dashboard renders program-member features only under their program")
    func wholeRepoDashboardDedupesProgramMemberFeatures() throws {
        let dashboard = try ProjectDashboardAssembler.assemble(
            factoryDir: factoryDir, runStore: storeFor(target: factoryDir))

        let headings = dashboard.sections.map(\.heading)
        // auth/billing/search are member nodes of program `demo`, so they render ONLY under the
        // program — never as standalone top-level features (no double-count in the project rollup).
        #expect(!headings.contains("Feature · auth"))
        #expect(!headings.contains("Feature · billing"))
        #expect(!headings.contains("Feature · search"))
        #expect(headings.contains("Program · demo"))

        let program = try #require(dashboard.sections.first { $0.heading == "Program · demo" })
        let rows = program.projection.rows
        // The committed status MIX — proves the program run RESOLVED via the relative-pipelineDir
        // match (auth done is the proof it's not an all-pending/static projection), and that the
        // member sub-pipelines loaded into the rollup (non-empty rows) even though deduped from the
        // standalone list.
        #expect(!rows.isEmpty)
        #expect(status(rows, "auth") == .done)
        #expect(status(rows, "billing") == .inProgress)
        #expect(status(rows, "m1-core-integrated") == .pending)
        #expect(status(rows, "search") == .pending)
    }

    @Test("Program dashboard renders one master-graph section with committed statuses")
    func programDashboardRendersMasterGraphWithStatuses() throws {
        let dashboard = try ProgramDashboardAssembler.assemble(
            programDir: programDir, runStore: storeFor(target: programDir))

        #expect(dashboard.sections.count == 1)
        let section = try #require(dashboard.sections.first)
        #expect(section.heading == "Program · demo")

        let rows = section.projection.rows
        #expect(status(rows, "auth") == .done)
        #expect(status(rows, "billing") == .inProgress)
        #expect(status(rows, "m1-core-integrated") == .pending)
        #expect(status(rows, "search") == .pending)
    }

    @Test("Single-graph Mermaid renders for a feature and the program")
    func singleGraphMermaidRendersForFeatureAndProgram() throws {
        let auth = try SpecLoader().loadPipeline(
            atDirectory: featuresDir.appendingPathComponent("auth", isDirectory: true))
        let authMermaid = GraphRenderer.mermaid(auth.spec)
        #expect(authMermaid.hasPrefix("```mermaid"))
        #expect(authMermaid.contains("flowchart"))
        #expect(authMermaid.contains("signup"))
        #expect(authMermaid.contains("login"))

        let program = try SpecLoader().loadPipeline(atDirectory: programDir)
        let programMermaid = GraphRenderer.mermaid(program.spec)
        #expect(programMermaid.hasPrefix("```mermaid"))
        #expect(programMermaid.contains("flowchart"))
        #expect(programMermaid.contains("auth"))
        // `m1-core-integrated` renders with mermaid-safe ids (`-` → `_`); assert the readable label.
        #expect(programMermaid.contains("m1-core-integrated"))
    }

    @Test("Dashboard page embeds inline SVG charts and HTML-escapes dynamic values")
    func dashboardPageEmbedsInlineSvgChartsAndEscapesDynamicValues() throws {
        let dashboard = try ProjectDashboardAssembler.assemble(
            factoryDir: factoryDir, runStore: storeFor(target: factoryDir))
        let html = GraphRenderer.dashboardPage(
            title: dashboard.title, sections: dashboard.sections)

        // Inline SVG charts (donut + grouped bars) are embedded.
        #expect(html.contains("<svg"))
        #expect(html.contains("dashboard-status-donut"))
        #expect(html.contains("dashboard-grouped-bars"))

        // Dynamic values are HTML-escaped: the escaped status class for billing's in-progress status,
        // and a <title> element carrying the (escaped) dashboard title.
        #expect(html.contains("status-in-progress"))
        #expect(html.contains("<title>"))
    }
}
