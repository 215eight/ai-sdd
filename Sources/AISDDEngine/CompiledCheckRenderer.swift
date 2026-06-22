import Foundation
import AISDDModels

/// The engine *edge* that serializes a `SchemaCompiler.CompiledCheck` into committed-shape
/// `kind: Check` YAML (A7) — kept out of the compiler core so the core stays encoder-free and
/// purely keyed off the schema. The rendered shape mirrors the hand-committed
/// `checks/<name>.structure.check.yaml`: an `apiVersion`/`kind`/`metadata`/`spec` envelope with only
/// the fields the `CheckSpec` actually carries (no fabricated keys), prefixed by an origin tag
/// comment so a reader can tell an auto-generated check from an authored marker.
public enum CompiledCheckRenderer {
    public static let apiVersion = "ai-sdd/v1"

    /// The committed-shape YAML for one compiled check, with a leading `# origin: …` tag comment.
    public static func yaml(_ check: SchemaCompiler.CompiledCheck) -> String {
        var lines: [String] = []
        lines.append("# origin: \(check.origin.rawValue)")
        lines.append("apiVersion: \(apiVersion)")
        lines.append("kind: Check")
        lines.append("metadata: { name: \(check.name) }")
        lines.append("spec:")
        if let checkKind = check.spec.checkKind {
            lines.append("  checkKind: \(checkKind)")
        }
        if let command = check.spec.command {
            lines.append("  command: \(quote(command))")
        }
        if let required = check.spec.required {
            lines.append("  required: \(required)")
        }
        return lines.joined(separator: "\n")
    }

    /// Render a list of compiled checks as one YAML stream, each a document separated by `---`.
    public static func yaml(_ checks: [SchemaCompiler.CompiledCheck]) -> String {
        checks.map(yaml).joined(separator: "\n---\n")
    }

    /// Double-quote a scalar the way the committed checks do (their `command` is always quoted).
    /// Escapes embedded quotes/backslashes so the output stays valid YAML.
    private static func quote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
