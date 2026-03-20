import AVFoundation
import Foundation

@MainActor
public final class SpeechPlaybackService: NSObject {
    private let synthesizer = AVSpeechSynthesizer()

    public override init() {
        super.init()
    }

    public func speak(_ text: String, language: SupportedLanguage) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = AVSpeechSynthesisVoice(language: language.bcP47Tag)
        utterance.rate = 0.46
        utterance.pitchMultiplier = 1.0
        synthesizer.speak(utterance)
    }

    public func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}
