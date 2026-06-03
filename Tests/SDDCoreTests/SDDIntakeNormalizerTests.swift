import Foundation
import SDDCore
import SDDModels
import XCTest

final class SDDIntakeNormalizerTests: XCTestCase {
    func testNormalizePRDProducesSingleSlicePlanningPayload() throws {
        let core = SDDCore(workspace: SDDWorkspaceConfiguration(root: temporaryWorkspace(), stack: "swift"))

        let normalized = try core.normalizeIntake(markdown: """
        ---
        intake_type: prd
        title: Checkout Flow
        source_id: prd-123
        owner: payments
        ---
        # Overview

        Ship a checkout flow for logged-in customers.

        ## Success Criteria

        Customers can complete payment.
        """)

        XCTAssertEqual(normalized.intakeType, .prd)
        XCTAssertEqual(normalized.title, "Checkout Flow")
        XCTAssertEqual(normalized.sourceId, "prd-123")
        XCTAssertEqual(normalized.owner, "payments")
        XCTAssertEqual(normalized.productIntent, "# Overview\n\nShip a checkout flow for logged-in customers.\n\n## Success Criteria\n\nCustomers can complete payment.")
        XCTAssertEqual(normalized.featureCatalog, [
            FeatureCatalogEntry(
                featureSlug: "checkout-flow",
                title: "Checkout Flow",
                description: "Ship a checkout flow for logged-in customers."
            )
        ])
        XCTAssertEqual(normalized.dependencyGraph, [])
        XCTAssertEqual(normalized.stackAssignments, [
            StackAssignment(featureSlug: "checkout-flow", stack: "swift")
        ])
        XCTAssertEqual(normalized.closedDecisions, [])
        XCTAssertEqual(normalized.executionStatus, [
            SliceExecutionStatus(featureSlug: "checkout-flow", status: .pending)
        ])
        XCTAssertEqual(normalized.sliceReadyRequirements, [
            SliceReadyRequirement(
                featureSlug: "checkout-flow",
                title: "Checkout Flow",
                body: "# Overview\n\nShip a checkout flow for logged-in customers.\n\n## Success Criteria\n\nCustomers can complete payment.",
                acceptanceSurface: .none,
                alternativesRequired: false
            )
        ])
    }

    func testNormalizePartnerChallengeSupportsQuotedFrontMatterValues() throws {
        let core = SDDCore(workspace: SDDWorkspaceConfiguration(root: temporaryWorkspace(), stack: "ai"))

        let normalized = try core.normalizeIntake(markdown: """
        ---
        intake_type: partner_challenge
        title: "Hiring Partner Challenge"
        owner: 'talent'
        ---
        The partner challenge should close requirements before implementation.

        Options considered include keeping the legacy challenge-only artifact.
        """)

        XCTAssertEqual(normalized.intakeType, .partnerChallenge)
        XCTAssertEqual(normalized.title, "Hiring Partner Challenge")
        XCTAssertEqual(normalized.owner, "talent")
        XCTAssertEqual(normalized.featureCatalog.first?.featureSlug, "hiring-partner-challenge")
        XCTAssertEqual(normalized.stackAssignments.first?.stack, "ai")
        XCTAssertEqual(normalized.sliceReadyRequirements.first?.alternativesRequired, true)
    }

    func testNormalizeUsesExplicitAcceptanceSurfaceFrontMatter() throws {
        let core = SDDCore(workspace: SDDWorkspaceConfiguration(root: temporaryWorkspace(), stack: "swift"))

        let normalized = try core.normalizeIntake(markdown: """
        ---
        intake_type: prd
        title: Import Customers CLI
        acceptance_surface: cli_workflow
        ---
        Operators import customers with a terminal command.
        """)

        XCTAssertEqual(normalized.sliceReadyRequirements.first?.acceptanceSurface, .cliWorkflow)
    }

    func testNormalizeInfersAcceptanceSurfaceWhenFrontMatterIsOmitted() throws {
        let core = SDDCore(workspace: SDDWorkspaceConfiguration(root: temporaryWorkspace(), stack: "swift"))

        let normalized = try core.normalizeIntake(markdown: """
        ---
        intake_type: prd
        title: Billing API
        ---
        Expose a public API endpoint for billing account lookup.
        """)

        XCTAssertEqual(normalized.sliceReadyRequirements.first?.acceptanceSurface, .publicAPI)
    }

    func testNormalizeRejectsUnsupportedAcceptanceSurface() throws {
        let core = SDDCore(workspace: SDDWorkspaceConfiguration(root: temporaryWorkspace()))

        XCTAssertThrowsError(
            try core.normalizeIntake(markdown: """
            ---
            intake_type: prd
            title: Checkout Flow
            acceptance_surface: funnel
            ---
            Checkout flow body.
            """)
        ) { error in
            XCTAssertEqual(
                error as? SDDCoreError,
                .intakeParseFailed("Unsupported acceptance_surface `funnel`. Supported values: none, ui_user_workflow, public_api, cli_workflow, operator_workflow.")
            )
        }
    }

    func testNormalizeRejectsUnsupportedIntakeType() throws {
        let core = SDDCore(workspace: SDDWorkspaceConfiguration(root: temporaryWorkspace()))

        XCTAssertThrowsError(
            try core.normalizeIntake(markdown: """
            ---
            intake_type: rfc
            title: Architecture RFC
            ---
            RFC body.
            """)
        ) { error in
            XCTAssertEqual(error as? SDDCoreError, .unsupportedIntakeType("rfc"))
        }
    }

    func testNormalizeRejectsMissingFrontMatter() throws {
        let core = SDDCore(workspace: SDDWorkspaceConfiguration(root: temporaryWorkspace()))

        XCTAssertThrowsError(
            try core.normalizeIntake(markdown: "No front matter.")
        ) { error in
            XCTAssertEqual(
                error as? SDDCoreError,
                .intakeParseFailed("Intake document must start with YAML front matter.")
            )
        }
    }

    private func temporaryWorkspace() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-sdd-intake-tests")
            .appendingPathComponent(UUID().uuidString)
    }
}
