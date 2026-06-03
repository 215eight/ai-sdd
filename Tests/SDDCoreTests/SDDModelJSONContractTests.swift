import Foundation
import SDDModels
import XCTest

final class SDDModelJSONContractTests: XCTestCase {
    func testRunSummaryJSONContract() throws {
        let summary = sampleRunSummary()
        let object = try jsonObject(summary)

        XCTAssertEqual(object["run_id"] as? String, "run_contract")
        XCTAssertEqual(object["feature_slug"] as? String, "checkout-flow")
        XCTAssertEqual(object["status"] as? String, "action_required")
        XCTAssertEqual(object["current_phase"] as? String, "plan")
        XCTAssertEqual(object["active_adapter"] as? String, "codex")
        XCTAssertNotNil(object["identity_attribution"])
        XCTAssertNotNil(object["lock"])
        XCTAssertNotNil(object["phase_history"])
        XCTAssertNotNil(object["approvals"])
        XCTAssertNotNil(object["blockers"])
        XCTAssertNotNil(object["telemetry_refs"])
        XCTAssertNotNil(object["token_usage_summary"])

        let identity = try XCTUnwrap(object["identity_attribution"] as? [String: Any])
        XCTAssertEqual(identity["actor_id"] as? String, "agent_session_123")
        XCTAssertEqual(identity["actor_type"] as? String, "agent")
        XCTAssertEqual(identity["agent_adapter"] as? String, "codex")
        XCTAssertEqual(identity["repo_id"] as? String, "example/checkout")
        XCTAssertEqual(identity["workspace_id"] as? String, "workspace-contract")
        XCTAssertEqual(identity["machine_id"] as? String, "machine-contract")
        XCTAssertEqual(identity["organization_id"] as? String, "org-contract")

        let decoded = try decode(RunSummary.self, from: summary)
        XCTAssertEqual(decoded, summary)
    }

    func testRunSummaryDecodesLegacyPayloadWithoutIdentityAttribution() throws {
        let data = Data(
            """
            {
              "run_id": "run_legacy",
              "feature_slug": "checkout-flow",
              "status": "action_required",
              "current_phase": "plan",
              "active_adapter": "codex",
              "lock": null,
              "phase_history": [],
              "approvals": [],
              "blockers": [],
              "telemetry_refs": [],
              "token_usage_summary": []
            }
            """.utf8
        )

        let decoded = try decoder().decode(RunSummary.self, from: data)

        XCTAssertEqual(decoded.identityAttribution.actorId, "unknown")
        XCTAssertEqual(decoded.identityAttribution.actorType, .agent)
        XCTAssertEqual(decoded.identityAttribution.agentAdapter, .codex)
    }

    func testTransitionInputJSONContract() throws {
        let input = TransitionInput(
            runSummary: sampleRunSummary(),
            artifactRefs: [ArtifactRef(type: "openspec_design", path: "openspec/changes/checkout-flow/design.md")],
            latestSubmittedResult: sampleExecutionResult(),
            workspaceContext: WorkspaceContext(repo: "example/checkout", stack: "swift")
        )
        let object = try jsonObject(input)

        XCTAssertNotNil(object["run_summary"])
        XCTAssertNotNil(object["artifact_refs"])
        XCTAssertNotNil(object["latest_submitted_result"])
        XCTAssertNotNil(object["workspace_context"])

        let decoded = try decode(TransitionInput.self, from: input)
        XCTAssertEqual(decoded, input)
    }

    func testTransitionResultJSONContract() throws {
        let result = TransitionResult(
            runId: "run_contract",
            featureSlug: "checkout-flow",
            status: .actionRequired,
            phase: .plan,
            agentRole: "sdd-planner",
            action: WorkflowAction(
                kind: .produceArtifact,
                instruction: "Produce a plan.",
                requiredInputs: [ArtifactRef(type: "openspec_proposal", path: "openspec/changes/checkout-flow/proposal.md")],
                requiredOutputs: [ArtifactRef(type: "openspec_tasks", path: "openspec/changes/checkout-flow/tasks.md")]
            ),
            completionContract: CompletionContract(submitPhase: .plan, requiresHumanApproval: true),
            blockedReason: nil,
            failedReason: nil
        )
        let object = try jsonObject(result)

        XCTAssertEqual(object["schema_version"] as? String, "1.0.0")
        XCTAssertEqual(object["run_id"] as? String, "run_contract")
        XCTAssertEqual(object["feature_slug"] as? String, "checkout-flow")
        XCTAssertEqual(object["status"] as? String, "action_required")
        XCTAssertEqual(object["phase"] as? String, "plan")
        XCTAssertEqual(object["agent_role"] as? String, "sdd-planner")
        XCTAssertNotNil(object["action"])
        XCTAssertNotNil(object["completion_contract"])
        XCTAssertNil(object["blocked_reason"])
        XCTAssertNil(object["failed_reason"])

        let action = try XCTUnwrap(object["action"] as? [String: Any])
        XCTAssertEqual(action["kind"] as? String, "produce_artifact")
        XCTAssertNotNil(action["required_inputs"])
        XCTAssertNotNil(action["required_outputs"])

        let completion = try XCTUnwrap(object["completion_contract"] as? [String: Any])
        XCTAssertEqual(completion["submit_phase"] as? String, "plan")
        XCTAssertEqual(completion["requires_human_approval"] as? Bool, true)

        let decoded = try decode(TransitionResult.self, from: result)
        XCTAssertEqual(decoded, result)
    }

    func testExecutionAdapterResultJSONContract() throws {
        let result = sampleExecutionResult()
        let object = try jsonObject(result)

        XCTAssertEqual(object["adapter"] as? String, "claude-code")
        XCTAssertEqual(object["status"] as? String, "ok")
        XCTAssertNotNil(object["artifact_refs"])
        XCTAssertEqual(object["log_ref"] as? String, "logs/run_contract.log")
        XCTAssertNotNil(object["telemetry_refs"])
        XCTAssertNotNil(object["token_usage"])
        XCTAssertNil(object["error"])

        let decoded = try decode(ExecutionAdapterResult.self, from: result)
        XCTAssertEqual(decoded, result)
    }

    func testExecutionAdapterInvocationJSONContract() throws {
        let invocation = ExecutionAdapterInvocation(
            adapter: .codex,
            runId: "run_contract",
            featureSlug: "checkout-flow",
            phase: .plan,
            agentRole: "sdd-planner",
            prompt: "Execute the workflow action.",
            requiredInputs: [
                ArtifactRef(type: "openspec_proposal", path: "openspec/changes/checkout-flow/proposal.md")
            ],
            requiredOutputs: [
                ArtifactRef(type: "openspec_design", path: "openspec/changes/checkout-flow/design.md")
            ],
            completionContract: CompletionContract(submitPhase: .plan, requiresHumanApproval: true),
            submitCommand: "sdd submit-result --run-id run_contract --phase plan --json < result.json"
        )
        let object = try jsonObject(invocation)

        XCTAssertEqual(object["schema_version"] as? String, "1.0.0")
        XCTAssertEqual(object["adapter"] as? String, "codex")
        XCTAssertEqual(object["run_id"] as? String, "run_contract")
        XCTAssertEqual(object["feature_slug"] as? String, "checkout-flow")
        XCTAssertEqual(object["phase"] as? String, "plan")
        XCTAssertEqual(object["agent_role"] as? String, "sdd-planner")
        XCTAssertEqual(object["prompt"] as? String, "Execute the workflow action.")
        XCTAssertNotNil(object["required_inputs"])
        XCTAssertNotNil(object["required_outputs"])
        XCTAssertNotNil(object["completion_contract"])
        XCTAssertEqual(object["submit_command"] as? String, "sdd submit-result --run-id run_contract --phase plan --json < result.json")

        let decoded = try decode(ExecutionAdapterInvocation.self, from: invocation)
        XCTAssertEqual(decoded, invocation)
    }

    func testTelemetryEventJSONContract() throws {
        let event = TelemetryEvent(
            eventId: "evt_contract",
            eventName: "sdd.transition",
            runId: "run_contract",
            featureSlug: "checkout-flow",
            phase: .plan,
            status: .actionRequired,
            adapter: .codex,
            interface: .cli,
            timestamp: sampleDate(),
            identityAttribution: sampleIdentityAttribution(),
            properties: ["policy": "passed"]
        )
        let object = try jsonObject(event)

        XCTAssertEqual(object["event_id"] as? String, "evt_contract")
        XCTAssertEqual(object["event_name"] as? String, "sdd.transition")
        XCTAssertEqual(object["run_id"] as? String, "run_contract")
        XCTAssertEqual(object["feature_slug"] as? String, "checkout-flow")
        XCTAssertEqual(object["phase"] as? String, "plan")
        XCTAssertEqual(object["status"] as? String, "action_required")
        XCTAssertEqual(object["adapter"] as? String, "codex")
        XCTAssertEqual(object["interface"] as? String, "cli")
        XCTAssertEqual(object["timestamp"] as? String, "2026-06-03T20:00:00Z")
        XCTAssertNotNil(object["identity_attribution"])
        XCTAssertNotNil(object["properties"])

        let decoded = try decode(TelemetryEvent.self, from: event)
        XCTAssertEqual(decoded, event)
    }

    func testTokenAttributionJSONContract() throws {
        let attribution = sampleTokenAttribution()
        let object = try jsonObject(attribution)

        XCTAssertEqual(object["provider"] as? String, "openai")
        XCTAssertEqual(object["model"] as? String, "gpt-5.5")
        XCTAssertEqual(object["input_tokens"] as? Int, 117_940)
        XCTAssertEqual(object["output_tokens"] as? Int, 501)
        XCTAssertEqual(object["cached_tokens"] as? Int, 31_616)
        XCTAssertEqual(object["reasoning_tokens"] as? Int, 275)
        XCTAssertEqual(object["confidence"] as? String, "session_scoped")

        let decoded = try decode(TokenAttribution.self, from: attribution)
        XCTAssertEqual(decoded, attribution)
    }

    func testCapabilitiesJSONContract() throws {
        let capabilities = Capabilities(
            supportedCommands: ["capabilities", "start"],
            supportedOperations: ["start_run", "get_next_action"],
            supportedOutputModes: ["json"],
            supportedInterfaceModes: [.cli],
            compatibility: "mvp-cli"
        )
        let object = try jsonObject(capabilities)

        XCTAssertEqual(object["schema_version"] as? String, "1.0.0")
        XCTAssertEqual(object["protocol_version"] as? String, "0.1.0")
        XCTAssertEqual(object["core_version"] as? String, "0.1.0")
        XCTAssertNotNil(object["supported_commands"])
        XCTAssertNotNil(object["supported_operations"])
        XCTAssertNotNil(object["supported_output_modes"])
        XCTAssertNotNil(object["supported_interface_modes"])
        XCTAssertEqual(object["compatibility"] as? String, "mvp-cli")

        let decoded = try decode(Capabilities.self, from: capabilities)
        XCTAssertEqual(decoded, capabilities)
    }

    func testWorkspaceValidationReportJSONContract() throws {
        let report = WorkspaceValidationReport(
            valid: false,
            root: "/workspace",
            openspecRoot: "/workspace/openspec",
            telemetryPath: "/workspace/.sdd/telemetry/events.jsonl",
            repoId: "example/repo",
            workspaceId: "local",
            stack: "swift",
            machineId: "machine-contract",
            organizationId: "org-contract",
            checks: [
                WorkspaceValidationCheck(
                    name: "workspace_root_exists",
                    status: .failed,
                    path: "/workspace",
                    message: "Workspace root does not exist."
                )
            ]
        )
        let object = try jsonObject(report)

        XCTAssertEqual(object["schema_version"] as? String, "1.0.0")
        XCTAssertEqual(object["valid"] as? Bool, false)
        XCTAssertEqual(object["root"] as? String, "/workspace")
        XCTAssertEqual(object["openspec_root"] as? String, "/workspace/openspec")
        XCTAssertEqual(object["telemetry_path"] as? String, "/workspace/.sdd/telemetry/events.jsonl")
        XCTAssertEqual(object["repo_id"] as? String, "example/repo")
        XCTAssertEqual(object["workspace_id"] as? String, "local")
        XCTAssertEqual(object["stack"] as? String, "swift")
        XCTAssertEqual(object["machine_id"] as? String, "machine-contract")
        XCTAssertEqual(object["organization_id"] as? String, "org-contract")

        let checks = try XCTUnwrap(object["checks"] as? [[String: Any]])
        XCTAssertEqual(checks.first?["name"] as? String, "workspace_root_exists")
        XCTAssertEqual(checks.first?["status"] as? String, "failed")
        XCTAssertEqual(checks.first?["path"] as? String, "/workspace")
        XCTAssertEqual(checks.first?["message"] as? String, "Workspace root does not exist.")

        let decoded = try decode(WorkspaceValidationReport.self, from: report)
        XCTAssertEqual(decoded, report)
    }

    func testArtifactValidationReportJSONContract() throws {
        let report = ArtifactValidationReport(
            featureSlug: "checkout-flow",
            valid: false,
            artifacts: [
                ArtifactStatus(
                    ref: ArtifactRef(type: "openspec_design", path: "openspec/changes/checkout-flow/design.md"),
                    required: true,
                    state: .placeholder,
                    byteCount: 64
                )
            ],
            issues: [
                ArtifactValidationIssue(
                    ref: ArtifactRef(type: "openspec_design", path: "openspec/changes/checkout-flow/design.md"),
                    reason: .placeholder,
                    message: "Required OpenSpec artifact still contains scaffold placeholder content."
                )
            ]
        )
        let object = try jsonObject(report)

        XCTAssertEqual(object["feature_slug"] as? String, "checkout-flow")
        XCTAssertEqual(object["valid"] as? Bool, false)
        XCTAssertNotNil(object["artifacts"])
        XCTAssertNotNil(object["issues"])

        let artifacts = try XCTUnwrap(object["artifacts"] as? [[String: Any]])
        XCTAssertEqual(artifacts.first?["required"] as? Bool, true)
        XCTAssertEqual(artifacts.first?["state"] as? String, "placeholder")
        XCTAssertEqual(artifacts.first?["byte_count"] as? Int, 64)

        let issues = try XCTUnwrap(object["issues"] as? [[String: Any]])
        XCTAssertEqual(issues.first?["reason"] as? String, "placeholder")
        XCTAssertEqual(issues.first?["message"] as? String, "Required OpenSpec artifact still contains scaffold placeholder content.")

        let decoded = try decode(ArtifactValidationReport.self, from: report)
        XCTAssertEqual(decoded, report)
    }

    func testNormalizedIntakeJSONContract() throws {
        let normalized = NormalizedIntake(
            intakeType: .prd,
            title: "Checkout Flow",
            sourceId: "prd-123",
            owner: "payments",
            productIntent: "Ship checkout.",
            featureCatalog: [
                FeatureCatalogEntry(featureSlug: "checkout-flow", title: "Checkout Flow", description: "Ship checkout.")
            ],
            dependencyGraph: [
                DependencyEdge(fromFeatureSlug: "checkout-flow", toFeatureSlug: "payment-adapter")
            ],
            stackAssignments: [
                StackAssignment(featureSlug: "checkout-flow", stack: "swift")
            ],
            closedDecisions: [
                "Use CLI mode for the MVP."
            ],
            executionStatus: [
                SliceExecutionStatus(featureSlug: "checkout-flow", status: .pending)
            ],
            sliceReadyRequirements: [
                SliceReadyRequirement(
                    featureSlug: "checkout-flow",
                    title: "Checkout Flow",
                    body: "Ship checkout.",
                    acceptanceSurface: .none,
                    alternativesRequired: false
                )
            ]
        )
        let object = try jsonObject(normalized)

        XCTAssertEqual(object["schema_version"] as? String, "1.0.0")
        XCTAssertEqual(object["intake_type"] as? String, "prd")
        XCTAssertEqual(object["title"] as? String, "Checkout Flow")
        XCTAssertEqual(object["source_id"] as? String, "prd-123")
        XCTAssertEqual(object["owner"] as? String, "payments")
        XCTAssertEqual(object["product_intent"] as? String, "Ship checkout.")
        XCTAssertNotNil(object["feature_catalog"])
        XCTAssertNotNil(object["dependency_graph"])
        XCTAssertNotNil(object["stack_assignments"])
        XCTAssertNotNil(object["closed_decisions"])
        XCTAssertNotNil(object["execution_status"])
        XCTAssertNotNil(object["slice_ready_requirements"])

        let requirements = try XCTUnwrap(object["slice_ready_requirements"] as? [[String: Any]])
        XCTAssertEqual(requirements.first?["acceptance_surface"] as? String, "none")
        XCTAssertEqual(requirements.first?["alternatives_required"] as? Bool, false)

        let decoded = try decode(NormalizedIntake.self, from: normalized)
        XCTAssertEqual(decoded, normalized)
    }

    private func sampleRunSummary() -> RunSummary {
        RunSummary(
            runId: "run_contract",
            featureSlug: "checkout-flow",
            status: .actionRequired,
            currentPhase: .plan,
            activeAdapter: .codex,
            identityAttribution: sampleIdentityAttribution(),
            lock: LockInfo(owner: "agent_session_123", acquiredAt: sampleDate(), expiresAt: sampleDate().addingTimeInterval(3600)),
            phaseHistory: [
                PhaseHistoryEntry(phase: .plan, status: .actionRequired, at: sampleDate(), note: "run_started")
            ],
            approvals: [
                ApprovalRecord(gateId: "plan_approval", phase: .plan, approvedBy: "human", approvedAt: sampleDate())
            ],
            blockers: [
                BlockerRecord(reason: .missingInput, message: "Missing PRD.", at: sampleDate())
            ],
            telemetryRefs: [
                TelemetryRef(eventId: "evt_contract", traceId: "trace_contract")
            ],
            tokenUsageSummary: [sampleTokenAttribution()]
        )
    }

    private func sampleExecutionResult() -> ExecutionAdapterResult {
        ExecutionAdapterResult(
            adapter: .claudeCode,
            status: .ok,
            artifactRefs: [ArtifactRef(type: "openspec_design", path: "openspec/changes/checkout-flow/design.md")],
            logRef: "logs/run_contract.log",
            telemetryRefs: [TelemetryRef(eventId: "evt_contract", traceId: nil)],
            tokenUsage: sampleTokenAttribution(),
            error: nil
        )
    }

    private func sampleTokenAttribution() -> TokenAttribution {
        TokenAttribution(
            provider: "openai",
            model: "gpt-5.5",
            inputTokens: 117_940,
            outputTokens: 501,
            cachedTokens: 31_616,
            reasoningTokens: 275,
            confidence: .sessionScoped
        )
    }

    private func sampleIdentityAttribution() -> IdentityAttribution {
        IdentityAttribution(
            actorId: "agent_session_123",
            actorType: .agent,
            agentAdapter: .codex,
            repoId: "example/checkout",
            workspaceId: "workspace-contract",
            machineId: "machine-contract",
            organizationId: "org-contract"
        )
    }

    private func sampleDate() -> Date {
        Date(timeIntervalSince1970: 1_780_516_800)
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try encoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func decode<T: Codable>(_ type: T.Type, from value: T) throws -> T {
        let data = try encoder().encode(value)
        return try decoder().decode(type, from: data)
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
