import Foundation
import SDDModels

public struct WorkflowEngine {
    public init() {}

    public func evaluate(_ input: TransitionInput) -> TransitionResult {
        let summary = input.runSummary

        switch summary.status {
        case .completed, .failed, .blocked:
            return TransitionResult(
                runId: summary.runId,
                featureSlug: summary.featureSlug,
                status: summary.status,
                phase: summary.currentPhase,
                agentRole: nil,
                action: nil,
                completionContract: nil,
                blockedReason: summary.status == .blocked ? summary.blockers.last?.reason : nil,
                failedReason: summary.status == .failed ? .adapterExecutionFailed : nil
            )
        case .approvalRequired:
            return approvalRequired(summary)
        case .inputRequired:
            return inputRequired(summary)
        case .running:
            return TransitionResult(
                runId: summary.runId,
                featureSlug: summary.featureSlug,
                status: .running,
                phase: summary.currentPhase,
                agentRole: nil,
                action: nil,
                completionContract: nil,
                blockedReason: nil,
                failedReason: nil
            )
        case .actionRequired:
            return actionRequired(summary)
        }
    }

    private func actionRequired(_ summary: RunSummary) -> TransitionResult {
        switch summary.currentPhase {
        case .plan:
            return TransitionResult(
                runId: summary.runId,
                featureSlug: summary.featureSlug,
                status: .actionRequired,
                phase: .plan,
                agentRole: "sdd-planner",
                action: WorkflowAction(
                    kind: .produceArtifact,
                    instruction: "Produce a decision-closed implementation plan for the OpenSpec change.",
                    requiredInputs: [
                        ArtifactRef(type: "openspec_proposal", path: "openspec/changes/\(summary.featureSlug)/proposal.md"),
                        ArtifactRef(type: "openspec_decisions", path: "openspec/changes/\(summary.featureSlug)/decisions.md")
                    ],
                    requiredOutputs: [
                        ArtifactRef(type: "openspec_design", path: "openspec/changes/\(summary.featureSlug)/design.md"),
                        ArtifactRef(type: "openspec_tasks", path: "openspec/changes/\(summary.featureSlug)/tasks.md")
                    ]
                ),
                completionContract: CompletionContract(submitPhase: .plan, requiresHumanApproval: true),
                blockedReason: nil,
                failedReason: nil
            )
        case .implement:
            return TransitionResult(
                runId: summary.runId,
                featureSlug: summary.featureSlug,
                status: .actionRequired,
                phase: .implement,
                agentRole: "sdd-implementer",
                action: WorkflowAction(
                    kind: .executeTasks,
                    instruction: "Implement the approved OpenSpec task artifact and update the workspace.",
                    requiredInputs: [
                        ArtifactRef(type: "openspec_design", path: "openspec/changes/\(summary.featureSlug)/design.md"),
                        ArtifactRef(type: "openspec_tasks", path: "openspec/changes/\(summary.featureSlug)/tasks.md")
                    ],
                    requiredOutputs: []
                ),
                completionContract: CompletionContract(submitPhase: .implement, requiresHumanApproval: false),
                blockedReason: nil,
                failedReason: nil
            )
        case .review:
            return TransitionResult(
                runId: summary.runId,
                featureSlug: summary.featureSlug,
                status: .actionRequired,
                phase: .review,
                agentRole: "sdd-reviewer",
                action: WorkflowAction(
                    kind: .reviewChanges,
                    instruction: "Review the implementation against the OpenSpec design, tasks, architecture, and verification requirements.",
                    requiredInputs: [
                        ArtifactRef(type: "openspec_design", path: "openspec/changes/\(summary.featureSlug)/design.md"),
                        ArtifactRef(type: "openspec_tasks", path: "openspec/changes/\(summary.featureSlug)/tasks.md")
                    ],
                    requiredOutputs: [
                        ArtifactRef(type: "openspec_review", path: "openspec/changes/\(summary.featureSlug)/review.md")
                    ]
                ),
                completionContract: CompletionContract(submitPhase: .review, requiresHumanApproval: false),
                blockedReason: nil,
                failedReason: nil
            )
        }
    }

    private func approvalRequired(_ summary: RunSummary) -> TransitionResult {
        TransitionResult(
            runId: summary.runId,
            featureSlug: summary.featureSlug,
            status: .approvalRequired,
            phase: summary.currentPhase,
            agentRole: nil,
            action: WorkflowAction(
                kind: .requestApproval,
                instruction: "Request human approval for the current workflow gate.",
                requiredInputs: [
                    ArtifactRef(type: "openspec_design", path: "openspec/changes/\(summary.featureSlug)/design.md"),
                    ArtifactRef(type: "openspec_tasks", path: "openspec/changes/\(summary.featureSlug)/tasks.md")
                ],
                requiredOutputs: []
            ),
            completionContract: CompletionContract(submitPhase: summary.currentPhase, requiresHumanApproval: true),
            blockedReason: nil,
            failedReason: nil
        )
    }

    private func inputRequired(_ summary: RunSummary) -> TransitionResult {
        TransitionResult(
            runId: summary.runId,
            featureSlug: summary.featureSlug,
            status: .inputRequired,
            phase: summary.currentPhase,
            agentRole: nil,
            action: WorkflowAction(
                kind: .requestInput,
                instruction: "Request the missing human input needed to continue the workflow.",
                requiredInputs: [],
                requiredOutputs: []
            ),
            completionContract: nil,
            blockedReason: nil,
            failedReason: nil
        )
    }
}
