import CoreServices
import Foundation

public final class LexiconOverlay: @unchecked Sendable {
    private let protectedTerms: [String: [String]] = [
        "Apple": ["Apple", "แอปเปิล", "苹果"],
        "macOS": ["macOS", "แมคโอเอส", "macOS"],
        "iPhone": ["iPhone", "ไอโฟน", "iPhone"],
        "OpenAI": ["OpenAI", "OpenAI", "OpenAI"]
    ]

    public init() {}

    public func contextualStrings(for language: SupportedLanguage) -> [String] {
        let languageIndex: Int
        switch language {
        case .en: languageIndex = 0
        case .th: languageIndex = 1
        case .zhHans: languageIndex = 2
        case .ja, .fr, .de, .es, .ko: languageIndex = 0
        }

        return protectedTerms.values.compactMap { terms in
            guard terms.indices.contains(languageIndex) else { return nil }
            return terms[languageIndex]
        }
    }

    public func protectTerms(in translatedText: String, sourceText: String) -> String {
        var output = translatedText
        for variants in protectedTerms.values {
            guard let canonical = variants.first else { continue }
            if variants.contains(where: { sourceText.localizedCaseInsensitiveContains($0) }) {
                for variant in variants where variant != canonical {
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
