import Foundation
import NaturalLanguage

public struct LanguageScorer {
    public init() {}

    public func chooseBest(
        from hypotheses: [SupportedLanguage: RecognitionHypothesis],
        current: SupportedLanguage?
    ) -> RecognitionHypothesis? {
        let scored = hypotheses.values.map { hypothesis in
            (hypothesis, score(hypothesis))
        }

        guard let best = scored.max(by: { $0.1 < $1.1 }) else {
            return nil
        }

        guard let current, let currentHypothesis = hypotheses[current] else {
            return best.0
        }

        let currentScore = score(currentHypothesis) + 0.08
        if currentScore >= best.1 {
            return currentHypothesis
        }

        return best.0
    }

    public func score(_ hypothesis: RecognitionHypothesis) -> Double {
        let trimmed = hypothesis.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)

        let dominantLanguage = recognizer.dominantLanguage
        let languageBonus: Double
        switch (hypothesis.language, dominantLanguage) {
        case (.zhHans, .simplifiedChinese), (.en, .english), (.th, .thai):
            languageBonus = 0.25
        case (.ja, .japanese), (.fr, .french), (.de, .german), (.es, .spanish), (.ko, .korean):
            languageBonus = 0.25
        default:
            languageBonus = 0
        }

        let scriptBonus = hypothesis.language.scriptScore(for: trimmed) * 0.35
        let lengthBonus = min(Double(trimmed.count) / 40.0, 0.15)

        return hypothesis.confidence * 0.45 + hypothesis.averageSegmentConfidence * 0.20 + languageBonus + scriptBonus + lengthBonus
    }
}
