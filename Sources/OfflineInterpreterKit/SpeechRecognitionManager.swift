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

    public init(lexiconOverlay: LexiconOverlay) {
        self.lexiconOverlay = lexiconOverlay
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
    }

    public func appendPCMBuffer(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let activeStreams = Array(streams.values)
        lock.unlock()
        activeStreams.forEach { $0.append(buffer) }
    }

    public func appendSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        let activeStreams = Array(streams.values)
        lock.unlock()
        activeStreams.forEach { $0.append(sampleBuffer) }
    }

    public func reconfigure(mode: LanguageSelectionMode) throws {
        try start(mode: mode)
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

private final class SpeechRecognizerStream {
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
        request.addsPunctuation = true
        request.contextualStrings = contextualStrings
        self.request = request

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let error {
                if !self.isStopped {
                    self.onError(error)
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
}
