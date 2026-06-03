import ArgumentParser
import Foundation
import SDDCore
import SDDModels

@main
struct SDDCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sdd",
        abstract: "Spec-Driven Development workflow CLI.",
        subcommands: [
            CapabilitiesCommand.self,
            StartCommand.self,
            NextCommand.self,
            SubmitResultCommand.self,
            AnswerPromptCommand.self,
            ApproveGateCommand.self,
            StatusCommand.self,
            ListArtifactsCommand.self,
            GetArtifactCommand.self,
            ValidateArtifactsCommand.self,
            NormalizeIntakeCommand.self,
            GetRunSummaryCommand.self,
            ListRunEventsCommand.self,
            PrepareExecutionCommand.self
        ]
    )
}

struct CommonOptions: ParsableArguments {
    @Option(help: "Workspace root.")
    var workspace: String = FileManager.default.currentDirectoryPath

    @Flag(help: "Emit structured JSON output.")
    var json = false

    func core() -> SDDCore {
        let root = URL(fileURLWithPath: workspace)
        return SDDCore(workspace: SDDWorkspaceConfiguration(root: root))
    }
}

struct CapabilitiesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "capabilities")

    @OptionGroup var common: CommonOptions

    func run() throws {
        try emit(common.core().capabilities())
    }
}

struct StartCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "start")

    @OptionGroup var common: CommonOptions

    @Option(name: .long, help: "Feature slug.")
    var feature: String?

    @Option(name: .customLong("intake-file"), help: "Markdown intake file with front matter.")
    var intakeFile: String?

    @Option(help: "Execution adapter.")
    var adapter: AgentAdapter = .codex

    @Option(help: "Lock owner.")
    var owner: String = NSUserName()

    func run() throws {
        let result: TransitionResult
        switch (feature, intakeFile) {
        case (.some(let feature), .none):
            result = try common.core().startRun(featureSlug: feature, adapter: adapter, owner: owner)
        case (.none, .some(let intakeFile)):
            let markdown = try String(contentsOf: URL(fileURLWithPath: intakeFile), encoding: .utf8)
            result = try common.core().startRun(intakeMarkdown: markdown, adapter: adapter, owner: owner)
        case (.some, .some):
            throw ValidationError("Use either --feature or --intake-file, not both.")
        case (.none, .none):
            throw ValidationError("Provide --feature or --intake-file.")
        }
        try emit(result)
    }
}

struct NextCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "next")

    @OptionGroup var common: CommonOptions

    @Option(name: .long, help: "Run ID.")
    var runId: String

    func run() throws {
        let result = try common.core().nextAction(runId: runId)
        try emit(result)
    }
}

struct SubmitResultCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "submit-result")

    @OptionGroup var common: CommonOptions

    @Option(name: .long, help: "Run ID.")
    var runId: String

    @Option(help: "Submitted workflow phase.")
    var phase: WorkflowPhase

    @Option(help: "JSON file containing ExecutionAdapterResult. Reads stdin when omitted.")
    var input: String?

    func run() throws {
        let data: Data
        if let input {
            data = try Data(contentsOf: URL(fileURLWithPath: input))
        } else {
            data = FileHandle.standardInput.readDataToEndOfFile()
        }
        let result = try SDDJSONBridge.decoder().decode(ExecutionAdapterResult.self, from: data)
        try emit(try common.core().submitResult(runId: runId, phase: phase, result: result))
    }
}

struct AnswerPromptCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "answer-prompt")

    @OptionGroup var common: CommonOptions

    @Option(name: .long, help: "Run ID.")
    var runId: String

    @Option(name: .long, help: "Prompt ID.")
    var promptId: String

    @Option(help: "Prompt answer.")
    var answer: String

    func run() throws {
        try emit(try common.core().answerPrompt(runId: runId, promptId: promptId, answer: answer))
    }
}

struct ApproveGateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "approve-gate")

    @OptionGroup var common: CommonOptions

    @Option(name: .long, help: "Run ID.")
    var runId: String

    @Option(help: "Approved workflow phase.")
    var phase: WorkflowPhase

    @Option(help: "Approving actor.")
    var approvedBy: String = NSUserName()

    func run() throws {
        try emit(try common.core().approveGate(runId: runId, phase: phase, approvedBy: approvedBy))
    }
}

struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status")

    @OptionGroup var common: CommonOptions

    @Option(name: .long, help: "Run ID.")
    var runId: String

    func run() throws {
        try emit(try common.core().status(runId: runId))
    }
}

struct GetRunSummaryCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get-run-summary")

    @OptionGroup var common: CommonOptions

    @Option(name: .long, help: "Run ID.")
    var runId: String

    func run() throws {
        try emit(try common.core().getRunSummary(runId: runId))
    }
}

struct ListRunEventsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list-run-events")

    @OptionGroup var common: CommonOptions

    @Option(name: .long, help: "Run ID.")
    var runId: String

    func run() throws {
        try emit(try common.core().listRunEvents(runId: runId))
    }
}

struct PrepareExecutionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "prepare-execution")

    @OptionGroup var common: CommonOptions

    @Option(name: .long, help: "Run ID.")
    var runId: String

    @Option(help: "Execution adapter override. Defaults to the run active adapter.")
    var adapter: AgentAdapter?

    func run() throws {
        try emit(try common.core().prepareExecution(runId: runId, adapter: adapter))
    }
}

struct ListArtifactsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list-artifacts")

    @OptionGroup var common: CommonOptions

    @Option(name: .long, help: "Feature slug.")
    var feature: String

    func run() throws {
        try emit(try common.core().listArtifacts(featureSlug: feature))
    }
}

struct GetArtifactCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get-artifact")

    @OptionGroup var common: CommonOptions

    @Option(name: .long, help: "Feature slug.")
    var feature: String

    @Option(help: "Artifact type, for example openspec_design.")
    var type: String

    func run() throws {
        try emit(try common.core().getArtifact(featureSlug: feature, type: type))
    }
}

struct ValidateArtifactsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "validate-artifacts")

    @OptionGroup var common: CommonOptions

    @Option(name: .long, help: "Feature slug.")
    var feature: String

    func run() throws {
        try emit(try common.core().validateArtifacts(featureSlug: feature))
    }
}

struct NormalizeIntakeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "normalize-intake")

    @OptionGroup var common: CommonOptions

    @Option(help: "Markdown intake file with front matter.")
    var file: String

    func run() throws {
        let url = URL(fileURLWithPath: file)
        let markdown = try String(contentsOf: url, encoding: .utf8)
        try emit(try common.core().normalizeIntake(markdown: markdown))
    }
}

struct CLIEnvelope<Payload: Encodable>: Encodable {
    var ok: Bool
    var data: Payload
    var error: String?
    var warnings: [String]
    var schemaVersion: String
    var protocolVersion: String
    var coreVersion: String
}

enum SDDJSONBridge {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

func emit<Payload: Encodable>(_ payload: Payload) throws {
    let envelope = CLIEnvelope(
        ok: true,
        data: payload,
        error: nil,
        warnings: [],
        schemaVersion: SDDConstants.schemaVersion,
        protocolVersion: SDDConstants.protocolVersion,
        coreVersion: SDDConstants.coreVersion
    )
    let data = try SDDJSONBridge.encoder().encode(envelope)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

extension WorkflowPhase: ExpressibleByArgument {}
extension AgentAdapter: ExpressibleByArgument {}
