import Foundation
import Testing
@testable import OfflineInterpreterKit

struct TranscriptSegmentReducerTests {
    @Test
    func mergesOverlappingStableSegments() {
        let start = Date()
        let first = TranslationSegment(
            sourceLanguage: .ru,
            targetLanguage: .zhHans,
            sourceText: "Исследований мы будем активизировать движущие силы развития",
            translatedText: "研究，我们将通过合作激活发展的动力",
            isStable: true,
            startedAt: start,
            updatedAt: start
        )
        let second = TranslationSegment(
            sourceLanguage: .ru,
            targetLanguage: .zhHans,
            sourceText: "Исследований мы будем активизировать движущие силы развития через экономическое сотрудничество",
            translatedText: "研究，我们将通过经济合作激活发展的动力",
            isStable: true,
            startedAt: start.addingTimeInterval(1),
            updatedAt: start.addingTimeInterval(1)
        )

        let reduced = TranscriptSegmentReducer.coalesce([first, second])

        #expect(reduced.count == 1)
        #expect(reduced[0].sourceText == second.sourceText)
        #expect(reduced[0].translatedText == second.translatedText)
    }

    @Test
    func keepsDistinctStableSegmentsSeparate() {
        let start = Date()
        let first = TranslationSegment(
            sourceLanguage: .ru,
            targetLanguage: .zhHans,
            sourceText: "Сегодня мы обсудим торговое сотрудничество.",
            translatedText: "今天我们将讨论贸易合作。",
            isStable: true,
            startedAt: start,
            updatedAt: start
        )
        let second = TranslationSegment(
            sourceLanguage: .ru,
            targetLanguage: .zhHans,
            sourceText: "Следующий вопрос посвящен студенческому обмену.",
            translatedText: "下一个议题是学生交流。",
            isStable: true,
            startedAt: start.addingTimeInterval(4),
            updatedAt: start.addingTimeInterval(4)
        )

        let reduced = TranscriptSegmentReducer.coalesce([first, second])

        #expect(reduced.count == 2)
    }

    @Test
    func collapsesExtendedFollowUpParagraphsIntoLatestVersion() {
        let start = Date()
        let first = TranslationSegment(
            sourceLanguage: .ru,
            targetLanguage: .zhHans,
            sourceText: "Сегодня мы обсудим образовательное сотрудничество между университетами России и Китая.",
            translatedText: "今天我们将讨论俄罗斯与中国高校之间的教育合作。",
            isStable: true,
            startedAt: start,
            updatedAt: start
        )
        let second = TranslationSegment(
            sourceLanguage: .ru,
            targetLanguage: .zhHans,
            sourceText: "Сегодня мы обсудим образовательное сотрудничество между университетами России и Китая. Далее перейдем к научным обменам и совместным лабораториям.",
            translatedText: "今天我们将讨论俄罗斯与中国高校之间的教育合作，随后再谈科研交流和联合实验室。",
            isStable: true,
            startedAt: start.addingTimeInterval(1.8),
            updatedAt: start.addingTimeInterval(1.8)
        )

        let reduced = TranscriptSegmentReducer.coalesce([first, second])

        #expect(reduced.count == 1)
        #expect(reduced[0].sourceText == second.sourceText)
        #expect(reduced[0].translatedText == second.translatedText)
    }

    @Test
    func displaySegmentsKeepStableSentenceAndAppendLiveSentence() {
        let start = Date()
        let stable = TranslationSegment(
            sourceLanguage: .ru,
            targetLanguage: .zhHans,
            sourceText: "Китайско-российский экономический диалог объединяет ведущих ученых и дипломатов.",
            translatedText: "中俄经济对话汇集了顶尖学者和外交官。",
            isStable: true,
            startedAt: start,
            updatedAt: start
        )
        let live = TranslationSegment(
            sourceLanguage: .ru,
            targetLanguage: .zhHans,
            sourceText: "Китайско-российский экономический диалог объединяет ведущих ученых и дипломатов из Китая и России.",
            translatedText: "中俄经济对话汇集了来自中国和俄罗斯的顶尖学者与外交官。",
            isStable: false,
            startedAt: start,
            updatedAt: start.addingTimeInterval(0.8)
        )

        let reduced = TranscriptSegmentReducer.composeDisplaySegments(
            stableSegments: [stable],
            liveSegment: live
        )

        #expect(reduced.count == 2)
        #expect(reduced[0].sourceText == stable.sourceText)
        #expect(reduced[0].translatedText == stable.translatedText)
        #expect(reduced[0].isStable == true)
        #expect(reduced[1].sourceText == live.sourceText)
        #expect(reduced[1].translatedText == live.translatedText)
        #expect(reduced[1].isStable == false)
    }

    @Test
    func displaySegmentsDoNotReplaceStableSentenceWhenLiveReusesSameID() {
        let start = Date()
        let sharedID = UUID()
        let stable = TranslationSegment(
            id: sharedID,
            sourceLanguage: .ru,
            targetLanguage: .zhHans,
            sourceText: "这是已经完成的一句。",
            translatedText: "This is the completed sentence.",
            isStable: true,
            startedAt: start,
            updatedAt: start
        )
        let live = TranslationSegment(
            id: sharedID,
            sourceLanguage: .ru,
            targetLanguage: .zhHans,
            sourceText: "这是下一句正在滚动的内容。",
            translatedText: "This is the next live sentence.",
            isStable: false,
            startedAt: start.addingTimeInterval(1),
            updatedAt: start.addingTimeInterval(1)
        )

        let reduced = TranscriptSegmentReducer.composeDisplaySegments(
            stableSegments: [stable],
            liveSegment: live
        )

        #expect(reduced.count == 2)
        #expect(reduced[0].sourceText == stable.sourceText)
        #expect(reduced[0].isStable == true)
        #expect(reduced[1].sourceText == live.sourceText)
        #expect(reduced[1].isStable == false)
        #expect(reduced[0].id != reduced[1].id)
    }
}
