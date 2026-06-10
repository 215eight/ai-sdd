import Foundation
import FactoryModels

/// Loads specs by decoding them into the strict Codable types — decode == structural
/// validation (ADR-0020). This slice decodes JSON (no dependency); the same types load
/// YAML via Yams later with no logic change.
public struct SpecLoader: Sendable {
    public init() {}

    public func loadPipeline(_ data: Data) throws -> SpecEnvelope<PipelineSpec> {
        try JSONDecoder().decode(SpecEnvelope<PipelineSpec>.self, from: data)
    }

    public func loadWorker(_ data: Data) throws -> SpecEnvelope<WorkerSpec> {
        try JSONDecoder().decode(SpecEnvelope<WorkerSpec>.self, from: data)
    }
}
