import Foundation
import Yams
import FactoryModels

/// A structural violation of a Schema's fields/invariants.
public struct SchemaViolation: Equatable, Sendable {
    public var field: String
    public var message: String
    public init(field: String, message: String) { self.field = field; self.message = message }
}

/// The deterministic Tier-1 executor: checks a structured artifact against a Schema's
/// `fields` + `invariants` and returns the violations (empty == valid). A compiled Tier-1
/// check invokes this (via `factory check`); the engine then gates on its exit status.
public enum SchemaValidator {
    public static func validate(_ schema: SchemaSpec, artifactYAML: String) throws -> [SchemaViolation] {
        let object = (try Yams.load(yaml: artifactYAML)) as? [String: Any] ?? [:]
        var violations: [SchemaViolation] = []
        for (name, field) in (schema.fields ?? [:]).sorted(by: { $0.key < $1.key }) {
            let value = object[name]
            if field.required == true, value == nil || value is NSNull {
                violations.append(.init(field: name, message: "missing required field"))
                continue
            }
            guard let value, !(value is NSNull) else { continue }   // optional + absent → skip
            for invariant in field.invariants ?? [] {
                evaluate(invariant, value: value, field: name, into: &violations)
            }
        }
        return violations
    }

    private static func evaluate(_ inv: Invariant, value: Any, field: String,
                                 into violations: inout [SchemaViolation]) {
        if inv.nonEmpty == true, isEmpty(value) {
            violations.append(.init(field: field, message: "must be non-empty"))
        }
        if let eq = inv.eq, scalar(value) != eq {
            violations.append(.init(field: field, message: "must equal '\(eq)' (was '\(scalar(value))')"))
        }
        if let pattern = inv.matches, !matches(scalar(value), pattern) {
            violations.append(.init(field: field, message: "must match /\(pattern)/ (was '\(scalar(value))')"))
        }
        if let all = inv.all {
            guard let list = value as? [Any] else {
                violations.append(.init(field: field, message: "expected a list for `all`"))
                return
            }
            for (index, element) in list.enumerated() {
                let target: Any? = all.field.map { (element as? [String: Any])?[$0] } ?? element
                let label = all.field.map { "\(field)[\(index)].\($0)" } ?? "\(field)[\(index)]"
                if all.nonEmpty == true, target == nil || isEmpty(target!) {
                    violations.append(.init(field: label, message: "must be non-empty"))
                }
                if let eq = all.eq, scalar(target) != eq {
                    violations.append(.init(field: label, message: "must equal '\(eq)' (was '\(scalar(target))')"))
                }
                if let pattern = all.matches, !matches(scalar(target), pattern) {
                    violations.append(.init(field: label, message: "must match /\(pattern)/ (was '\(scalar(target))')"))
                }
            }
        }
    }

    private static func scalar(_ value: Any?) -> String {
        switch value {
        case nil, is NSNull: return ""
        case let s as String: return s
        case let b as Bool: return b ? "true" : "false"
        case let i as Int: return String(i)
        case let d as Double: return String(d)
        case let value?: return "\(value)"
        }
    }

    private static func isEmpty(_ value: Any) -> Bool {
        if let s = value as? String { return s.isEmpty }
        if let a = value as? [Any] { return a.isEmpty }
        if let m = value as? [String: Any] { return m.isEmpty }
        return false
    }

    private static func matches(_ string: String, _ pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        return regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil
    }
}
