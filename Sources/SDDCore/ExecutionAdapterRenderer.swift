import Foundation
import SDDModels

public struct ExecutionAdapterRenderer {
    private let adapter: AgentAdapter

    public init(adapter: AgentAdapter) {
        self.adapter = adapter
    }

    public func render(
        runId: String,
        featureSlug: String,
        phase: WorkflowPhase,
        agentRole: String,
        action: WorkflowAction,
        completionContract: CompletionContract
    ) -> ExecutionAdapterInvocation {
        let requiredInputs = renderRefs(action.requiredInputs)
        let requiredOutputs = renderRefs(action.requiredOutputs)
        let adapterName = adapter.rawValue
        let prompt = """
        Adapter: \(adapterName)
        Role: \(agentRole)
        Run ID: \(runId)
        Feature slug: \(featureSlug)
        Phase: \(phase.rawValue)

        Execute the workflow action exactly as specified.

        Instruction:
        \(action.instruction)

        Required inputs:
        \(requiredInputs)

        Required outputs:
        \(requiredOutputs)

        Completion:
        Submit an ExecutionAdapterResult for phase `\(completionContract.submitPhase.rawValue)` after the required outputs are written.
        Human approval required after submit: `\(completionContract.requiresHumanApproval)`.
        """

        return ExecutionAdapterInvocation(
            adapter: adapter,
            runId: runId,
            featureSlug: featureSlug,
            phase: phase,
            agentRole: agentRole,
            prompt: prompt,
            requiredInputs: action.requiredInputs,
            requiredOutputs: action.requiredOutputs,
            completionContract: completionContract,
            submitCommand: "sdd submit-result --run-id \(runId) --phase \(completionContract.submitPhase.rawValue) --json < result.json"
        )
    }

    private func renderRefs(_ refs: [ArtifactRef]) -> String {
        if refs.isEmpty {
            return "None."
        }

        return refs
            .map { "- \($0.type): \($0.path)" }
            .joined(separator: "\n")
    }
}
