import Foundation
import SDDModels

#if canImport(Security)
import Security
#endif

public protocol SecretResolving {
    func resolve(_ reference: SecretReference) throws -> String
    func validate(_ references: [SecretReference]) -> SecretValidationReport
}

public final class RuntimeSecretResolver: SecretResolving {
    private let environment: [String: String]
    private let keychainLookup: (SecretReference) -> String?

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        keychainLookup: @escaping (SecretReference) -> String? = RuntimeSecretResolver.lookupKeychainSecret
    ) {
        self.environment = environment
        self.keychainLookup = keychainLookup
    }

    public func resolve(_ reference: SecretReference) throws -> String {
        switch reference.source {
        case .environment, .ci:
            if let value = environment[reference.key], !value.isEmpty {
                return value
            }
        case .keychain:
            if let value = keychainLookup(reference), !value.isEmpty {
                return value
            }
        }

        throw SDDCoreError.secretMissing("Secret \(reference.name) is not configured.")
    }

    public func validate(_ references: [SecretReference]) -> SecretValidationReport {
        let checks = references.map { reference in
            let configured = (try? resolve(reference)) != nil
            return SecretValidationCheck(
                name: reference.name,
                source: reference.source,
                key: reference.key,
                configured: configured,
                message: configured
                    ? "Secret reference is configured."
                    : "Missing secret reference \(reference.source.rawValue):\(reference.key)."
            )
        }

        return SecretValidationReport(
            valid: checks.allSatisfy(\.configured),
            checks: checks
        )
    }

    public static func lookupKeychainSecret(_ reference: SecretReference) -> String? {
        #if canImport(Security)
        let parts = reference.key.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            return nil
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: parts[0],
            kSecAttrAccount as String: parts[1],
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
        #else
        return nil
        #endif
    }
}

public enum TelemetryRedactor {
    private static let sensitiveKeyFragments = [
        "api_key",
        "apikey",
        "auth",
        "bearer",
        "connection_string",
        "credential",
        "password",
        "secret",
        "signed_url",
        "token"
    ]

    private static let allowedTokenUsageKeys = [
        "cached_tokens",
        "input_tokens",
        "output_tokens",
        "reasoning_tokens",
        "token_confidence",
        "token_model",
        "token_provider"
    ]

    public static func redact(_ properties: [String: String]) -> [String: String] {
        properties.mapValues { value in
            redactValue(value)
        }.mapValuesWithKeys { key, value in
            shouldRedactKey(key) ? "[REDACTED]" : value
        }
    }

    public static func redactValue(_ value: String) -> String {
        if containsSensitiveValue(value) {
            return "[REDACTED]"
        }
        return value
    }

    private static func shouldRedactKey(_ key: String) -> Bool {
        let normalized = key.lowercased()
        if allowedTokenUsageKeys.contains(normalized) {
            return false
        }
        return sensitiveKeyFragments.contains { normalized.contains($0) }
    }

    private static func containsSensitiveValue(_ value: String) -> Bool {
        let normalized = value.lowercased()
        if normalized.hasPrefix("bearer ") || normalized.contains("authorization:") {
            return true
        }
        if normalized.contains("x-amz-signature=") || normalized.contains("sig=") {
            return true
        }
        return false
    }
}

private extension Dictionary {
    func mapValuesWithKeys<NewValue>(_ transform: (Key, Value) -> NewValue) -> [Key: NewValue] {
        Dictionary<Key, NewValue>(
            uniqueKeysWithValues: map { key, value in
                (key, transform(key, value))
            }
        )
    }
}
