import CoreServices
import Foundation

public final class LexiconOverlay: @unchecked Sendable {
    private let protectedTerms: [String: [SupportedLanguage: String]] = [
        "Apple": [
            .en: "Apple",
            .th: "แอปเปิล",
            .zhHans: "苹果",
            .ru: "Эппл",
            .it: "Apple"
        ],
        "macOS": [
            .en: "macOS",
            .th: "แมคโอเอส",
            .zhHans: "macOS",
            .ru: "macOS",
            .it: "macOS"
        ],
        "iPhone": [
            .en: "iPhone",
            .th: "ไอโฟน",
            .zhHans: "iPhone",
            .ru: "айфон",
            .it: "iPhone"
        ],
        "OpenAI": [
            .en: "OpenAI",
            .th: "OpenAI",
            .zhHans: "OpenAI",
            .ru: "OpenAI",
            .it: "OpenAI"
        ]
    ]

    public init() {}

    public func contextualStrings(for language: SupportedLanguage) -> [String] {
        return protectedTerms.values.compactMap { terms in
            terms[language] ?? terms[.en]
        }
    }

    public func protectTerms(in translatedText: String, sourceText: String) -> String {
        var output = translatedText
        for variants in protectedTerms.values {
            let knownTerms = Array(variants.values)
            guard let canonical = variants[.en] ?? knownTerms.first else { continue }
            if knownTerms.contains(where: { sourceText.localizedCaseInsensitiveContains($0) }) {
                for variant in knownTerms where variant != canonical {
                    output = output.replacingOccurrences(of: variant, with: canonical)
                }
            }
        }
        return output
    }

    public func dictionaryDefinition(for token: String) -> String? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let nsRange = NSRange(location: 0, length: (trimmed as NSString).length)
        guard let definition = DCSCopyTextDefinition(nil, trimmed as CFString, CFRange(location: nsRange.location, length: nsRange.length)) else {
            return nil
        }

        return definition.takeRetainedValue() as String
    }
}
