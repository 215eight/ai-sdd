import Foundation
import Yams
import FactoryModels

/// A typed error from loading a spec, so callers (and tests) get the *exact* failure rather than
/// a raw `DecodingError` / Yams error. (ADR-0020: decode == structural validation.)
public enum SpecLoadError: Error, Sendable {
    case syntax(String)   // not well-formed (a YAML/JSON parse error)
    case schema(String)   // well-formed, but does not match the spec type (missing / wrong-typed field)
}

extension SpecLoadError: CustomStringConvertible, LocalizedError {
    public var description: String {
        switch self {
        case let .syntax(message): return "spec is not well-formed: \(message)"
        case let .schema(message): return "spec is invalid: \(message)"
        }
    }
    public var errorDescription: String? { description }
}

/// Loads specs by decoding them into the strict Codable types — decode == structural validation.
/// YAML is the on-disk format; the same Codable types also decode JSON (used by the unit tests).
public struct SpecLoader: Sendable {
    public init() {}

    public func loadPipelineYAML(_ yaml: String) throws -> SpecEnvelope<PipelineSpec> { try Self.decodeYAML(yaml) }
    public func loadWorkerYAML(_ yaml: String) throws -> SpecEnvelope<WorkerSpec> { try Self.decodeYAML(yaml) }
    public func loadPipeline(_ data: Data) throws -> SpecEnvelope<PipelineSpec> { try Self.decodeJSON(data) }
    public func loadWorker(_ data: Data) throws -> SpecEnvelope<WorkerSpec> { try Self.decodeJSON(data) }

    private static func decodeYAML<T: Decodable>(_ yaml: String) throws -> T {
        do { return try YAMLDecoder().decode(T.self, from: yaml) }
        catch { throw classify(error) }
    }

    private static func decodeJSON<T: Decodable>(_ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw classify(error) }
    }

    /// Classify a decoder failure: a malformed document (`.dataCorrupted`, or any non-`DecodingError`
    /// parser error) is `.syntax`; a well-formed document that doesn't match the type is `.schema`.
    /// (Note: `YAMLDecoder` reports YAML *syntax* errors as `DecodingError.dataCorrupted`, not a raw
    /// Yams error — so we branch on the case, not the error type.)
    private static func classify(_ error: Error) -> SpecLoadError {
        guard let decoding = error as? DecodingError else {
            return .syntax("\(error)")
        }
        if case let .dataCorrupted(context) = decoding {
            return .syntax(context.debugDescription)
        }
        return .schema(describe(decoding))
    }

    /// Turn a `DecodingError` into a precise, human-readable message (also drives the CLI output).
    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map(\.stringValue).joined(separator: ".")
        }
        switch error {
        case let .keyNotFound(key, _):
            return "missing required field '\(key.stringValue)'"
        case let .typeMismatch(type, context):
            return "wrong type at '\(path(context))' (expected \(type))"
        case let .valueNotFound(type, context):
            return "missing value at '\(path(context))' (expected \(type))"
        case let .dataCorrupted(context):
            return context.debugDescription
        @unknown default:
            return "\(error)"
        }
    }
}
