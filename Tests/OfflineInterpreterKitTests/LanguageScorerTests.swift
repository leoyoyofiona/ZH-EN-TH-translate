import Testing
@testable import OfflineInterpreterKit

struct LanguageScorerTests {
    @Test
    func thaiScriptWinsInAutoSelection() {
        let scorer = LanguageScorer()
        let hypotheses: [SupportedLanguage: RecognitionHypothesis] = [
            .en: RecognitionHypothesis(language: .en, text: "Sawasdee krub", confidence: 0.52, isFinal: false, averageSegmentConfidence: 0.52),
            .th: RecognitionHypothesis(language: .th, text: "สวัสดีครับ", confidence: 0.51, isFinal: false, averageSegmentConfidence: 0.51)
        ]

        let best = scorer.chooseBest(from: hypotheses, current: nil)

        #expect(best?.language == .th)
    }

    @Test
    func currentLanguageKeepsSmallLead() {
        let scorer = LanguageScorer()
        let hypotheses: [SupportedLanguage: RecognitionHypothesis] = [
            .en: RecognitionHypothesis(language: .en, text: "hello there", confidence: 0.70, isFinal: false, averageSegmentConfidence: 0.70),
            .zhHans: RecognitionHypothesis(language: .zhHans, text: "你好", confidence: 0.72, isFinal: false, averageSegmentConfidence: 0.72)
        ]

        let best = scorer.chooseBest(from: hypotheses, current: .en)

        #expect(best?.language == .en)
    }
}
