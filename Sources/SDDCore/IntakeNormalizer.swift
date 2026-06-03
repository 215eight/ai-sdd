import Foundation
import SDDModels

public struct IntakeNormalizer {
    private let workspace: SDDWorkspaceConfiguration

    public init(workspace: SDDWorkspaceConfiguration) {
        self.workspace = workspace
    }

    public func normalize(markdown: String) throws -> NormalizedIntake {
        let document = try parse(markdown: markdown)
        let featureSlug = slugify(document.title)
        let body = document.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = firstParagraph(from: body)
        let alternativesRequired = body.localizedCaseInsensitiveContains("alternative") ||
            body.localizedCaseInsensitiveContains("options considered") ||
            body.localizedCaseInsensitiveContains("open question")

        return NormalizedIntake(
            intakeType: document.intakeType,
            title: document.title,
            sourceId: document.sourceId,
            owner: document.owner,
            productIntent: body,
            featureCatalog: [
                FeatureCatalogEntry(
                    featureSlug: featureSlug,
                    title: document.title,
                    description: description
                )
            ],
            dependencyGraph: [],
            stackAssignments: [
                StackAssignment(featureSlug: featureSlug, stack: workspace.stack)
            ],
            closedDecisions: [],
            executionStatus: [
                SliceExecutionStatus(featureSlug: featureSlug, status: .pending)
            ],
            sliceReadyRequirements: [
                SliceReadyRequirement(
                    featureSlug: featureSlug,
                    title: document.title,
                    body: body,
                    acceptanceSurface: .none,
                    alternativesRequired: alternativesRequired
                )
            ]
        )
    }

    public func parse(markdown: String) throws -> IntakeDocument {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n") else {
            throw SDDCoreError.intakeParseFailed("Intake document must start with YAML front matter.")
        }

        guard let closingRange = normalized.range(of: "\n---\n", range: normalized.index(normalized.startIndex, offsetBy: 4)..<normalized.endIndex) else {
            throw SDDCoreError.intakeParseFailed("Intake front matter must be closed with --- on its own line.")
        }

        let frontMatterStart = normalized.index(normalized.startIndex, offsetBy: 4)
        let frontMatter = String(normalized[frontMatterStart..<closingRange.lowerBound])
        let bodyStart = closingRange.upperBound
        let body = String(normalized[bodyStart...])

        let metadata = try parseFrontMatter(frontMatter)
        guard let rawIntakeType = metadata["intake_type"], !rawIntakeType.isEmpty else {
            throw SDDCoreError.intakeParseFailed("Intake front matter requires intake_type.")
        }
        guard let intakeType = IntakeType(rawValue: rawIntakeType) else {
            throw SDDCoreError.unsupportedIntakeType(rawIntakeType)
        }
        guard let title = metadata["title"], !title.isEmpty else {
            throw SDDCoreError.intakeParseFailed("Intake front matter requires title.")
        }

        return IntakeDocument(
            intakeType: intakeType,
            title: title,
            sourceId: emptyToNil(metadata["source_id"]),
            owner: emptyToNil(metadata["owner"]),
            body: body
        )
    }

    private func parseFrontMatter(_ frontMatter: String) throws -> [String: String] {
        var metadata: [String: String] = [:]

        for rawLine in frontMatter.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                continue
            }
            if line.hasPrefix("#") {
                continue
            }
            guard let separator = line.firstIndex(of: ":") else {
                throw SDDCoreError.intakeParseFailed("Front matter line must use key: value syntax: \(line)")
            }

            let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            if key.isEmpty {
                throw SDDCoreError.intakeParseFailed("Front matter keys must not be empty.")
            }

            metadata[key] = stripScalarQuotes(rawValue)
        }

        return metadata
    }

    private func stripScalarQuotes(_ value: String) -> String {
        if value.count >= 2,
           let first = value.first,
           let last = value.last,
           (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    private func firstParagraph(from body: String) -> String {
        let lines = body
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        return lines.first ?? body
    }

    private func slugify(_ title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let scalars = folded.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(String(scalar).lowercased())
            }
            return "-"
        }
        let collapsed = String(scalars)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "untitled" : collapsed
    }

    private func emptyToNil(_ value: String?) -> String? {
        guard let value, !value.isEmpty else {
            return nil
        }
        return value
    }
}
