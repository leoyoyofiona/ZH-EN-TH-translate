import Foundation
import OfflineInterpreterKit

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw CheckFailure(description: message)
    }
}

@main
struct OfflineInterpreterChecks {
    static func main() throws {
        try expect(SupportedLanguage.allCases.count >= 8, "Expected expanded common-language support set")
        try expect(Set(SupportedLanguage.allCases.map(\.displayName)).count == SupportedLanguage.allCases.count, "Language display names should stay unique")
        try expect(SupportedLanguage.ja.scriptScore(for: "これは日本語の字幕です") > 0.2, "Japanese script score should recognize kana/kanji")
        try expect(SupportedLanguage.ko.scriptScore(for: "이것은 한국어 자막입니다") > 0.2, "Korean script score should recognize hangul")

        let scorer = LanguageScorer()
        let hypotheses: [SupportedLanguage: RecognitionHypothesis] = [
            .en: RecognitionHypothesis(language: .en, text: "Sawasdee krub", confidence: 0.52, isFinal: false, averageSegmentConfidence: 0.52),
            .th: RecognitionHypothesis(language: .th, text: "สวัสดีครับ", confidence: 0.51, isFinal: false, averageSegmentConfidence: 0.51)
        ]
        let best = scorer.chooseBest(from: hypotheses, current: nil)
        try expect(best?.language == .th, "Thai-script hypothesis should win auto selection")

        let overlay = LexiconOverlay()
        let protectedText = overlay.protectTerms(in: "แอปเปิล เปิดตัว iPhone รุ่นใหม่", sourceText: "Apple 发布了新 iPhone")
        try expect(protectedText.contains("Apple"), "Protected brand term Apple should remain canonical")
        try expect(protectedText.contains("iPhone"), "Protected term iPhone should remain canonical")

        let thaiTerms = overlay.contextualStrings(for: .th)
        try expect(thaiTerms.contains("แอปเปิล"), "Thai contextual lexicon should expose Apple")
        try expect(thaiTerms.contains("ไอโฟน"), "Thai contextual lexicon should expose iPhone")

        print("OfflineInterpreterChecks: PASS")
    }
}
