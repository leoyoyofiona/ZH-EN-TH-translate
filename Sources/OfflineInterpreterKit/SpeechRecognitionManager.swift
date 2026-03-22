import AVFoundation
import Foundation
import Speech

public final class SpeechRecognitionManager: @unchecked Sendable {
    public var onUpdate: ((SpeechPipelineUpdate) -> Void)?
    public var onError: ((Error) -> Void)?

    private let lexiconOverlay: LexiconOverlay
    private let scorer = LanguageScorer()
    private let lock = NSLock()

    private var mode: LanguageSelectionMode = .auto
    private var streams: [SupportedLanguage: SpeechRecognizerStream] = [:]
    private var hypotheses: [SupportedLanguage: RecognitionHypothesis] = [:]
    private var currentLanguage: SupportedLanguage?
    private var lastAudioInputAt: Date?
    private var lastRecognitionUpdateAt: Date?
    private var lastRecoveryAt: Date?

    public init(lexiconOverlay: LexiconOverlay) {
        self.lexiconOverlay = lexiconOverlay
    }

    public func healthSnapshot(now: Date = .now) -> RecognitionHealthSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return RecognitionHealthSnapshot(
            audioInputAge: lastAudioInputAt.map { now.timeIntervalSince($0) },
            recognitionUpdateAge: lastRecognitionUpdateAt.map { now.timeIntervalSince($0) },
            recoveryAge: lastRecoveryAt.map { now.timeIntervalSince($0) }
        )
    }

    public func start(mode: LanguageSelectionMode) throws {
        stop()
        self.mode = mode

        for language in candidateLanguages(for: mode) {
            let stream = try SpeechRecognizerStream(
                language: language,
                contextualStrings: lexiconOverlay.contextualStrings(for: language),
                onHypothesis: { [weak self] hypothesis in
                    self?.handle(hypothesis: hypothesis)
                },
                onError: { [weak self] error in
                    self?.onError?(error)
                }
            )
            stream.start()
            streams[language] = stream
        }
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        streams.values.forEach { $0.stop() }
        streams.removeAll()
        hypotheses.removeAll()
        currentLanguage = nil
        lastAudioInputAt = nil
        lastRecognitionUpdateAt = nil
        lastRecoveryAt = nil
    }

    public func appendPCMBuffer(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let activeStreams = Array(streams.values)
        lastAudioInputAt = .now
        lock.unlock()
        activeStreams.forEach { $0.append(buffer) }
    }

    public func appendSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        let activeStreams = Array(streams.values)
        lastAudioInputAt = .now
        lock.unlock()
        activeStreams.forEach { $0.append(sampleBuffer) }
    }

    public func reconfigure(mode: LanguageSelectionMode) throws {
        try start(mode: mode)
    }

    public func recoverIfStalled(mode: LanguageSelectionMode, now: Date = .now) throws -> Bool {
        lock.lock()
        let recentAudio = lastAudioInputAt.map { now.timeIntervalSince($0) <= 2.0 } ?? false
        let recognitionStale = lastRecognitionUpdateAt.map { now.timeIntervalSince($0) >= 4.0 } ?? true
        let cooldownElapsed = lastRecoveryAt.map { now.timeIntervalSince($0) >= 3.0 } ?? true
        let shouldRecover = recentAudio && recognitionStale && cooldownElapsed
        if shouldRecover {
            lastRecoveryAt = now
        }
        lock.unlock()

        guard shouldRecover else { return false }
        try start(mode: mode)
        return true
    }

    private func candidateLanguages(for mode: LanguageSelectionMode) -> [SupportedLanguage] {
        if case .manual(let language) = mode {
            return [language]
        }
        return SupportedLanguage.allCases
    }

    private func handle(hypothesis: RecognitionHypothesis) {
        let update: SpeechPipelineUpdate?
        lock.lock()
        hypotheses[hypothesis.language] = hypothesis

        let selectedHypothesis: RecognitionHypothesis?
        switch mode {
        case .manual(let language):
            selectedHypothesis = hypotheses[language]
        case .auto:
            selectedHypothesis = scorer.chooseBest(from: hypotheses, current: currentLanguage)
        }

        if let selectedHypothesis {
            currentLanguage = selectedHypothesis.language
            lastRecognitionUpdateAt = .now
            update = SpeechPipelineUpdate(
                sourceLanguage: selectedHypothesis.language,
                text: selectedHypothesis.text,
                confidence: selectedHypothesis.confidence,
                isStable: selectedHypothesis.isFinal,
                receivedAt: selectedHypothesis.receivedAt
            )
        } else {
            update = nil
        }

        if hypothesis.isFinal {
            hypotheses.removeAll()
        }
        lock.unlock()

        if let update, !update.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onUpdate?(update)
        }
    }
}

public struct RecognitionHealthSnapshot: Sendable {
    public let audioInputAge: TimeInterval?
    public let recognitionUpdateAge: TimeInterval?
    public let recoveryAge: TimeInterval?

    public var hasRecentAudioInput: Bool {
        guard let audioInputAge else { return false }
        return audioInputAge <= 2.0
    }

    public var recognitionIsStale: Bool {
        guard let recognitionUpdateAge else { return true }
        return recognitionUpdateAge >= 4.0
    }
}

private final class SpeechRecognizerStream: @unchecked Sendable {
    private let language: SupportedLanguage
    private let recognizer: SFSpeechRecognizer
    private let prefersOnDeviceRecognition: Bool
    private let contextualStrings: [String]
    private let onHypothesis: (RecognitionHypothesis) -> Void
    private let onError: (Error) -> Void

    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var isStopped = false
    private var lastDeliveredText = ""
    private var lastDeliveredWasFinal = false
    private var recoveryAttemptCount = 0

    init(
        language: SupportedLanguage,
        contextualStrings: [String],
        onHypothesis: @escaping (RecognitionHypothesis) -> Void,
        onError: @escaping (Error) -> Void
    ) throws {
        self.language = language
        self.contextualStrings = contextualStrings
        self.onHypothesis = onHypothesis
        self.onError = onError

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language.localeIdentifier)) else {
            throw NSError(domain: "OfflineInterpreter.SpeechRecognizerStream", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法创建 \(language.displayName) 识别器。"])
        }
        recognizer.defaultTaskHint = .dictation
        recognizer.queue = OperationQueue()
        recognizer.queue.qualityOfService = .userInitiated
        self.recognizer = recognizer
        self.prefersOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
    }

    func start() {
        isStopped = false
        createTask()
    }

    func stop() {
        isStopped = true
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        lastDeliveredText = ""
        lastDeliveredWasFinal = false
        recoveryAttemptCount = 0
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        request?.append(buffer)
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        request?.appendAudioSampleBuffer(sampleBuffer)
    }

    private func createTask() {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = prefersOnDeviceRecognition
        request.addsPunctuation = language.addsPunctuationDuringRecognition
        request.contextualStrings = contextualStrings
        self.request = request

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let error {
                if !self.isStopped {
                    if self.shouldAutoRecover(from: error) {
                        self.restartAfterTransientFailure()
                    } else {
                        self.onError(error)
                    }
                }
                return
            }

            guard let result else { return }
            let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            if text == self.lastDeliveredText && result.isFinal == self.lastDeliveredWasFinal {
                return
            }

            let segments = result.bestTranscription.segments
            let averageConfidence: Double
            if segments.isEmpty {
                averageConfidence = 0.5
            } else {
                averageConfidence = segments.reduce(0) { partialResult, segment in
                    partialResult + Double(segment.confidence)
                } / Double(segments.count)
            }

            let hypothesis = RecognitionHypothesis(
                language: self.language,
                text: text,
                confidence: max(averageConfidence, result.isFinal ? 0.9 : 0.55),
                isFinal: result.isFinal,
                receivedAt: .now,
                averageSegmentConfidence: averageConfidence
            )
            self.recoveryAttemptCount = 0
            self.lastDeliveredText = text
            self.lastDeliveredWasFinal = result.isFinal
            self.onHypothesis(hypothesis)

            if result.isFinal && !self.isStopped {
                self.task?.cancel()
                self.task = nil
                self.request = nil
                self.createTask()
            }
        }
    }

    private func restartAfterTransientFailure() {
        guard !isStopped else { return }

        task?.cancel()
        task = nil
        request = nil
        recoveryAttemptCount = min(recoveryAttemptCount + 1, 4)

        let delay = min(0.2 * Double(recoveryAttemptCount), 0.8)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.isStopped else { return }
            self.createTask()
        }
    }

    private func shouldAutoRecover(from error: Error) -> Bool {
        let nsError = error as NSError
        let lowered = [
            nsError.domain,
            nsError.localizedDescription,
            nsError.localizedFailureReason ?? "",
            nsError.localizedRecoverySuggestion ?? ""
        ]
        .joined(separator: " ")
        .lowercased()

        if lowered.contains("permission")
            || lowered.contains("not authorized")
            || lowered.contains("denied")
            || lowered.contains("unsupported locale")
            || lowered.contains("not available") {
            return false
        }

        return true
    }
}
