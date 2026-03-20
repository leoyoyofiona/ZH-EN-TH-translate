import Foundation
import Combine
import AppKit
import UniformTypeIdentifiers

@MainActor
public final class AppViewModel: ObservableObject {
    @Published public var audioSource: AudioSourceKind = .systemAudio
    @Published public var languageMode: LanguageSelectionMode = .manual(.en)
    @Published public var targetLanguage: SupportedLanguage = .zhHans
    @Published public var speakTranslations = false
    @Published public var sourceSubtitleColorStyle: SubtitleColorStyle = .system
    @Published public var translationSubtitleColorStyle: SubtitleColorStyle = .system
    @Published public var sourceFontSize: Double = 20
    @Published public var translationFontSize: Double = 28

    @Published public private(set) var runState: PipelineRunState = .idle
    @Published public private(set) var readinessReport: OfflineReadinessReport?
    @Published public private(set) var segments: [TranslationSegment] = []
    @Published public private(set) var liveSegment: TranslationSegment?
    @Published public private(set) var detectedLanguage: SupportedLanguage?
    @Published public private(set) var recognitionConfidence: Double = 0
    @Published public private(set) var latencyMilliseconds: Int = 0
    @Published public private(set) var statusMessage = "准备就绪。"
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var isRunning = false
    @Published public private(set) var transcriptRevision = 0

    private let launchDemoSnapshot: Bool

    private let readinessService = OfflineReadinessService()
    private let lexiconOverlay = LexiconOverlay()
    private let playbackService = SpeechPlaybackService()
    private lazy var translationPipeline = TranslationPipeline(lexiconOverlay: lexiconOverlay)
    private lazy var speechRecognition = SpeechRecognitionManager(lexiconOverlay: lexiconOverlay)

    private var activeCapture: AudioCaptureController?
    private var translationTask: Task<Void, Never>?
    private var silenceWatchdogTask: Task<Void, Never>?
    private var currentRevision = 0
    private var currentUtteranceStartedAt: Date?
    private var lastSpeechUpdate: SpeechPipelineUpdate?
    private var lastScheduledSignature: ScheduledSignature?
    private var hasAttemptedAutoStart = false
    private var cancellables: Set<AnyCancellable> = []
    private let maxStoredSegments = 240

    public init(launchDemoSnapshot: Bool = false) {
        self.launchDemoSnapshot = launchDemoSnapshot
        speechRecognition.onUpdate = { [weak self] update in
            Task { @MainActor [weak self] in
                self?.handleSpeechUpdate(update)
            }
        }
        speechRecognition.onError = { [weak self] error in
            Task { @MainActor [weak self] in
                self?.present(error: error)
            }
        }

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.handleAppBecameActive()
                }
            }
            .store(in: &cancellables)

        if launchDemoSnapshot {
            loadDemoSnapshot()
        } else {
            Task {
                await prepareForOverlayMode()
            }
        }
    }

    public var selectedSourceLanguage: SupportedLanguage {
        get { languageMode.manuallySelectedLanguage ?? .en }
        set { languageMode = .manual(newValue) }
    }

    public var subtitleText: String {
        if let liveSegment, !liveSegment.translatedText.isEmpty {
            return liveSegment.translatedText
        }
        return segments.last?.translatedText ?? "等待系统音频..."
    }

    public var currentSourceText: String {
        if let liveSegment, !liveSegment.sourceText.isEmpty {
            return liveSegment.sourceText
        }
        return segments.last?.sourceText ?? "Waiting for audio..."
    }

    public var currentTranslatedText: String {
        subtitleText
    }

    public var audioSourceDisplayName: String {
        audioSource.displayName
    }

    public var displayedSegments: [TranslationSegment] {
        var combined = segments
        if let liveSegment {
            if let index = combined.firstIndex(where: { $0.id == liveSegment.id }) {
                combined[index] = liveSegment
            } else {
                combined.append(liveSegment)
            }
        }
        return combined
    }

    public var compactStatusText: String {
        if let permissionIssue = permissionBlockingReason {
            return permissionIssue
        }
        if let firstReason = readinessReport?.blockingReasons.first {
            return firstReason
        }
        return statusMessage
    }

    public var translationDirectionStatusText: String {
        let pair = TranslationPair(source: selectedSourceLanguage, target: targetLanguage)
        switch readinessReport?.translationAvailability[pair] ?? .unknown {
        case .installed:
            return "\(selectedSourceLanguage.displayName) -> \(targetLanguage.displayName)：当前机器已支持离线翻译。"
        case .supported:
            return "\(selectedSourceLanguage.displayName) -> \(targetLanguage.displayName)：系统支持该语言对，但可能需要先准备语言资源。"
        case .unsupported:
            return "\(selectedSourceLanguage.displayName) -> \(targetLanguage.displayName)：当前系统不支持该语言对。"
        case .unknown:
            return "\(selectedSourceLanguage.displayName) -> \(targetLanguage.displayName)：正在检查系统翻译能力。"
        }
    }

    public var sourceRecognitionStatusText: String {
        guard let report = readinessReport else {
            return "语音识别能力：正在检查。"
        }

        let sourceLanguage = selectedSourceLanguage
        if report.onDeviceRecognition[sourceLanguage] == true {
            return "\(sourceLanguage.displayName) 识别：当前使用本地离线识别。"
        }
        return "\(sourceLanguage.displayName) 识别：当前机器缺少本地识别资源，已自动回退到联网识别。"
    }

    public var permissionBlockingReason: String? {
        guard let report = readinessReport else { return nil }
        if report.speechPermission != .authorized {
            return "语音识别权限未授权。"
        }

        switch audioSource {
        case .microphone:
            if report.microphonePermission != .authorized {
                return "麦克风权限未授权。"
            }
        case .systemAudio:
            if report.screenCapturePermission != .authorized {
                return "系统音频权限未授权。"
            }
        }

        return nil
    }

    public var canOpenSettings: Bool {
        permissionBlockingReason != nil
    }

    public func refreshReadiness() async {
        runState = .checkingReadiness
        let report = await readinessService.checkReadiness(
            for: audioSource,
            sourceLanguage: selectedSourceLanguage,
            targetLanguage: targetLanguage
        )
        readinessReport = report
        if isRunning {
            runState = .listening
        } else {
            runState = report.isReady ? .idle : .blocked
        }

        if let permissionIssue = permissionBlockingReason {
            statusMessage = permissionIssue
        } else if let firstReason = report.blockingReasons.first {
            statusMessage = firstReason
        } else if report.onDeviceRecognition[selectedSourceLanguage] == true {
            statusMessage = "离线资源检查通过。"
        } else {
            statusMessage = "当前机器缺少\(selectedSourceLanguage.displayName)本地识别资源，已切换为联网识别。"
        }
    }

    public func configureSourceLanguage(_ language: SupportedLanguage) {
        selectedSourceLanguage = language
        if targetLanguage == language {
            targetLanguage = defaultTargetLanguage(excluding: language)
        }
        handleLanguageModeChanged()
    }

    public func configureTargetLanguage(_ language: SupportedLanguage) {
        targetLanguage = language == selectedSourceLanguage ? defaultTargetLanguage(excluding: selectedSourceLanguage) : language
        handleTargetLanguageChanged()
    }

    public func startOrStop() {
        guard !launchDemoSnapshot else { return }
        if isRunning {
            Task { await stop() }
        } else {
            Task { await start() }
        }
    }

    public func handleAudioSourceChanged() {
        guard !launchDemoSnapshot else { return }
        Task {
            await readinessService.requestMissingPermissions(for: audioSource)
            await refreshReadiness()
            if isRunning {
                await restartPipeline(resetSegments: false)
            }
        }
    }

    public func handleLanguageModeChanged() {
        guard !launchDemoSnapshot else { return }
        Task {
            await refreshReadiness()
            if isRunning {
                await restartPipeline(resetSegments: false)
            }
        }
    }

    public func handleTargetLanguageChanged() {
        guard !launchDemoSnapshot else { return }
        Task {
            await refreshReadiness()
            if let lastSpeechUpdate {
                scheduleTranslation(for: lastSpeechUpdate, isStable: lastSpeechUpdate.isStable)
            }
        }
    }

    public func openRelevantSettings() {
        guard !launchDemoSnapshot else { return }
        let report = readinessReport
        if report?.speechPermission != .authorized {
            readinessService.openSpeechSettings()
            return
        }
        readinessService.openPrivacySettings(for: audioSource)
    }

    public func dictionaryDefinition(for token: String) -> String? {
        lexiconOverlay.dictionaryDefinition(for: token)
    }

    public func dismissError() {
        errorMessage = nil
    }

    public func loadDemoSnapshot(sourceLanguage: SupportedLanguage? = nil, targetLanguage: SupportedLanguage? = nil) {
        let demoSource = sourceLanguage ?? .en
        let demoTarget = targetLanguage ?? defaultTargetLanguage(excluding: demoSource)
        languageMode = .manual(demoSource)
        self.targetLanguage = demoTarget
        audioSource = .systemAudio
        runState = .idle
        isRunning = false
        readinessReport = nil
        detectedLanguage = demoSource
        recognitionConfidence = 0.96
        latencyMilliseconds = 84
        statusMessage = "演示模式：展示多语种原文与译文界面。"
        segments = demoSegments(sourceLanguage: demoSource, targetLanguage: demoTarget)
        liveSegment = nil
        transcriptRevision += 1
    }

    public func clearSubtitles() {
        segments.removeAll()
        liveSegment = nil
        currentUtteranceStartedAt = nil
        lastSpeechUpdate = nil
        lastScheduledSignature = nil
        transcriptRevision += 1
        statusMessage = "已清空当前字幕。"
    }

    public func exportTranscript(as format: TranscriptExportFormat) {
        let exportSegments = displayedSegments
        guard !exportSegments.isEmpty else {
            errorMessage = "当前没有可导出的原文和译文。"
            return
        }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = defaultExportFilename(for: format)
        if let contentType = contentType(for: format) {
            panel.allowedContentTypes = [contentType]
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let payload = try exportData(for: exportSegments, format: format)
            try payload.write(to: url, options: .atomic)
            statusMessage = "已导出到 \(url.lastPathComponent)。"
        } catch {
            present(error: error)
        }
    }

    private func start() async {
        errorMessage = nil
        statusMessage = "正在请求权限并准备离线资源。"
        runState = .checkingReadiness
        await readinessService.requestMissingPermissions(for: audioSource)
        await refreshReadiness()

        guard readinessReport?.isReady == true else {
            runState = .blocked
            return
        }

        do {
            let capture: AudioCaptureController = switch audioSource {
            case .microphone: MicrophoneAudioCapture()
            case .systemAudio: SystemAudioCapture()
            }

            capture.onPCMBuffer = { [weak self] buffer in
                self?.speechRecognition.appendPCMBuffer(buffer)
            }
            capture.onSampleBuffer = { [weak self] sampleBuffer in
                self?.speechRecognition.appendSampleBuffer(sampleBuffer)
            }

            try speechRecognition.start(mode: languageMode)
            await translationPipeline.prepare(source: selectedSourceLanguage, target: targetLanguage)
            try await capture.start()
            activeCapture = capture
            isRunning = true
            runState = .listening
            statusMessage = audioSource == .microphone ? "正在监听麦克风。" : "正在监听系统音频。"
        } catch {
            present(error: error)
            await stop()
        }
    }

    private func stop() async {
        translationTask?.cancel()
        silenceWatchdogTask?.cancel()
        speechRecognition.stop()
        await activeCapture?.stop()
        activeCapture = nil
        playbackService.stop()
        isRunning = false
        liveSegment = nil
        currentUtteranceStartedAt = nil
        lastSpeechUpdate = nil
        lastScheduledSignature = nil
        await refreshReadiness()
        statusMessage = readinessReport?.blockingReasons.first ?? "已停止。"
    }

    private func restartPipeline(resetSegments: Bool) async {
        await stop()
        if resetSegments {
            segments.removeAll()
        }
        await start()
    }

    private func prepareForOverlayMode() async {
        guard !launchDemoSnapshot else { return }
        await readinessService.requestMissingPermissions(for: audioSource)
        await refreshReadiness()

        guard !hasAttemptedAutoStart else { return }
        hasAttemptedAutoStart = true

        if readinessReport?.isReady == true {
            await start()
        }
    }

    private func handleAppBecameActive() async {
        guard !launchDemoSnapshot else { return }
        await refreshReadiness()

        guard !isRunning else { return }
        guard readinessReport?.isReady == true else { return }

        await start()
    }

    private func handleSpeechUpdate(_ update: SpeechPipelineUpdate) {
        if shouldIgnoreDuplicate(update) {
            scheduleSilenceWatchdog(after: silenceWatchdogDelay(for: update), from: update)
            return
        }

        detectedLanguage = update.sourceLanguage
        recognitionConfidence = update.confidence
        lastSpeechUpdate = update
        if currentUtteranceStartedAt == nil {
            currentUtteranceStartedAt = update.receivedAt
        }

        currentRevision += 1
        scheduleTranslation(for: update, isStable: update.isStable)
        scheduleSilenceWatchdog(after: silenceWatchdogDelay(for: update), from: update)
    }

    private func scheduleTranslation(for update: SpeechPipelineUpdate, isStable: Bool) {
        let revision = currentRevision
        translationTask?.cancel()
        lastScheduledSignature = ScheduledSignature(
            sourceLanguage: update.sourceLanguage,
            text: update.text,
            isStable: isStable
        )
        translationTask = Task { [weak self] in
            do {
                try await Task.sleep(for: self?.translationDebounce(for: update, isStable: isStable) ?? .milliseconds(80))
                guard !Task.isCancelled else { return }
                await self?.performTranslation(for: update, revision: revision, isStable: isStable)
            } catch {
                return
            }
        }
    }

    private func scheduleSilenceWatchdog(after seconds: Double, from update: SpeechPipelineUpdate) {
        silenceWatchdogTask?.cancel()
        let sourceText = update.text
        let sourceLanguage = update.sourceLanguage
        silenceWatchdogTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    guard self.isRunning else { return }
                    guard let lastSpeechUpdate = self.lastSpeechUpdate else { return }
                    guard lastSpeechUpdate.text == sourceText, !lastSpeechUpdate.isStable else { return }
                    self.currentRevision += 1
                    let forcedStableUpdate = SpeechPipelineUpdate(
                        sourceLanguage: sourceLanguage,
                        text: sourceText,
                        confidence: lastSpeechUpdate.confidence,
                        isStable: true,
                        receivedAt: .now
                    )
                    self.scheduleTranslation(for: forcedStableUpdate, isStable: true)
                }
            } catch {
                return
            }
        }
    }

    private func performTranslation(for update: SpeechPipelineUpdate, revision: Int, isStable: Bool) async {
        guard !update.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        runState = .translating
        let startedAt = currentUtteranceStartedAt ?? update.receivedAt

        do {
            let result = try await translationPipeline.translate(
                TranslationRequest(
                    sourceLanguage: update.sourceLanguage,
                    targetLanguage: targetLanguage,
                    sourceText: update.text,
                    revision: revision
                )
            )

            guard result.revision == currentRevision || isStable else { return }

            latencyMilliseconds = Int(result.completedAt.timeIntervalSince(update.receivedAt) * 1000)
            let segment = TranslationSegment(
                id: liveSegment?.id ?? UUID(),
                sourceLanguage: result.sourceLanguage,
                targetLanguage: result.targetLanguage,
                sourceText: result.sourceText,
                translatedText: result.translatedText,
                isStable: isStable,
                startedAt: startedAt,
                updatedAt: result.completedAt
            )

            if isStable {
                segments.append(segment)
                if segments.count > maxStoredSegments {
                    segments = Array(segments.suffix(maxStoredSegments))
                }
                liveSegment = nil
                currentUtteranceStartedAt = nil
                lastSpeechUpdate = nil
                statusMessage = "已完成一段离线翻译。"
                transcriptRevision += 1
                if speakTranslations {
                    playbackService.speak(result.translatedText, language: result.targetLanguage)
                    runState = .speaking
                } else {
                    runState = .listening
                }
            } else {
                liveSegment = segment
                runState = .translating
                statusMessage = "正在滚动翻译。"
                transcriptRevision += 1
            }
        } catch {
            present(error: error)
        }
    }

    private func translationDebounce(for update: SpeechPipelineUpdate, isStable: Bool) -> Duration {
        if isStable {
            return .milliseconds(8)
        }

        let punctuation = CharacterSet(charactersIn: ".!?。！？,，;；、")
        let lastScalar = update.text.unicodeScalars.last
        if let lastScalar, punctuation.contains(lastScalar) {
            return .milliseconds(20)
        }

        if update.text.count < 14 {
            return .milliseconds(28)
        }

        if update.text.count < 42 {
            return .milliseconds(42)
        }

        return .milliseconds(56)
    }

    private func silenceWatchdogDelay(for update: SpeechPipelineUpdate) -> Double {
        let punctuation = CharacterSet(charactersIn: ".!?。！？,，;；、")
        if let lastScalar = update.text.unicodeScalars.last, punctuation.contains(lastScalar) {
            return 0.18
        }
        if update.text.count < 12 {
            return 0.22
        }
        if update.text.count < 24 {
            return 0.28
        }
        return 0.34
    }

    private func shouldIgnoreDuplicate(_ update: SpeechPipelineUpdate) -> Bool {
        let signature = ScheduledSignature(
            sourceLanguage: update.sourceLanguage,
            text: update.text,
            isStable: update.isStable
        )

        if let lastScheduledSignature, lastScheduledSignature == signature {
            lastSpeechUpdate = update
            detectedLanguage = update.sourceLanguage
            recognitionConfidence = max(recognitionConfidence, update.confidence)
            return true
        }

        return false
    }

    private func defaultTargetLanguage(excluding source: SupportedLanguage) -> SupportedLanguage {
        source == .zhHans ? .en : .zhHans
    }

    private func demoSegments(sourceLanguage: SupportedLanguage, targetLanguage: SupportedLanguage) -> [TranslationSegment] {
        let samples = demoSampleText(sourceLanguage: sourceLanguage, targetLanguage: targetLanguage)
        let now = Date()

        return samples.enumerated().map { index, sample in
            let timestamp = now.addingTimeInterval(Double(index * 2))
            return TranslationSegment(
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                sourceText: sample.source,
                translatedText: sample.target,
                isStable: true,
                startedAt: timestamp,
                updatedAt: timestamp
            )
        }
    }

    private func demoSampleText(sourceLanguage: SupportedLanguage, targetLanguage: SupportedLanguage) -> [(source: String, target: String)] {
        switch (sourceLanguage, targetLanguage) {
        case (.en, .zhHans):
            return [
                ("The lecture starts in thirty seconds. Please open the next slide.", "讲座将在三十秒后开始，请打开下一张幻灯片。"),
                ("This app listens to system audio or your microphone and translates it in real time.", "这个应用可以监听系统音频或麦克风，并实时翻译。"),
                ("You can switch languages without restarting the app.", "你可以不重启应用，直接切换语言。")
            ]
        case (.zhHans, .en):
            return [
                ("现在开始测试中文到英文的同声翻译。", "We are now testing real-time translation from Chinese to English."),
                ("切换语言后，界面和导出内容都会同步更新。", "After switching languages, both the interface and exports update immediately."),
                ("目标是尽量保持低延迟和稳定输出。", "The goal is to keep latency low and output stable.")
            ]
        case (.th, .zhHans):
            return [
                ("ตอนนี้เรากำลังทดสอบการแปลภาษาไทยเป็นภาษาจีนแบบเรียลไทม์", "现在正在测试泰语到中文的实时翻译。"),
                ("แอปนี้รองรับเสียงจากไมโครโฟนและเสียงจากระบบ", "这个应用同时支持麦克风和系统音频。"),
                ("คุณสามารถบันทึกต้นฉบับและคำแปลลงในไฟล์ได้ทันที", "你可以立即把原文和译文导出为文件。")
            ]
        case (.ja, .zhHans):
            return [
                ("このアプリは再生中の音声をそのまま字幕化して翻訳します。", "这个应用可以直接把播放中的音频转成字幕并翻译。"),
                ("画面サイズを変えても、左右の字幕欄はそのまま使えます。", "即使调整窗口大小，左右字幕栏也能继续正常使用。"),
                ("必要なら後で文章をまとめてエクスポートできます。", "如果需要，之后还可以把文本统一导出。")
            ]
        case (.fr, .zhHans):
            return [
                ("L'application traduit la voix en temps réel sans envoyer l'interface à un service payant.", "这个应用可以实时翻译语音，而不依赖收费平台界面。"),
                ("Les sous-titres source et cible restent synchronisés pendant la lecture.", "播放时，原文字幕和译文字幕会保持同步。"),
                ("Vous pouvez exporter le texte en Word, TXT ou Markdown.", "你可以将文本导出为 Word、TXT 或 Markdown。")
            ]
        default:
            let source = "\(sourceLanguage.displayName) 实时字幕示例"
            let target = "\(targetLanguage.displayName) 实时翻译示例"
            return [
                (source, target),
                ("窗口支持自由缩放和拖拽分栏。", "The window supports free resizing and draggable split panes."),
                ("语言资源由系统按需提供，不把模型打包进应用。", "Language resources are provided on demand by the system, not bundled into the app.")
            ]
        }
    }

    private func defaultExportFilename(for format: TranscriptExportFormat) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "offline-transcript-\(formatter.string(from: .now)).\(format.fileExtension)"
    }

    private func contentType(for format: TranscriptExportFormat) -> UTType? {
        switch format {
        case .txt:
            return .plainText
        case .markdown:
            return UTType(filenameExtension: "md") ?? .plainText
        case .word:
            return UTType(filenameExtension: "docx")
        }
    }

    private func exportData(
        for exportSegments: [TranslationSegment],
        format: TranscriptExportFormat
    ) throws -> Data {
        switch format {
        case .txt:
            return Data(makePlainTranscript(from: exportSegments).utf8)
        case .markdown:
            return Data(makeMarkdownTranscript(from: exportSegments).utf8)
        case .word:
            let plainText = makePlainTranscript(from: exportSegments)
            let attributed = NSAttributedString(
                string: plainText,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13)
                ]
            )
            return try attributed.data(
                from: NSRange(location: 0, length: attributed.length),
                documentAttributes: [
                    .documentType: NSAttributedString.DocumentType.officeOpenXML
                ]
            )
        }
    }

    private func makePlainTranscript(from exportSegments: [TranslationSegment]) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm:ss"

        let header = [
            "离线同传导出",
            "源语言：\(selectedSourceLanguage.displayName)",
            "目标语言：\(targetLanguage.displayName)",
            "导出时间：\(DateFormatter.localizedString(from: .now, dateStyle: .medium, timeStyle: .medium))",
            ""
        ]

        let lines = exportSegments.map { segment in
            let timestamp = formatter.string(from: segment.updatedAt)
            return """
            [\(timestamp)]
            原文：\(segment.sourceText)
            译文：\(segment.translatedText)
            """
        }

        return (header + lines).joined(separator: "\n")
    }

    private func makeMarkdownTranscript(from exportSegments: [TranslationSegment]) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm:ss"

        let header = [
            "# 离线同传导出",
            "",
            "- 源语言：\(selectedSourceLanguage.displayName)",
            "- 目标语言：\(targetLanguage.displayName)",
            "- 导出时间：\(DateFormatter.localizedString(from: .now, dateStyle: .medium, timeStyle: .medium))",
            ""
        ]

        let blocks = exportSegments.map { segment in
            let timestamp = formatter.string(from: segment.updatedAt)
            return """
            ## \(timestamp)

            **原文**  
            \(segment.sourceText)

            **译文**  
            \(segment.translatedText)
            """
        }

        return (header + blocks).joined(separator: "\n\n")
    }

    private func present(error: Error) {
        if error is CancellationError {
            return
        }

        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError {
            return
        }

        errorMessage = error.localizedDescription
        statusMessage = error.localizedDescription
        runState = .error
    }
}

private struct ScheduledSignature: Equatable {
    let sourceLanguage: SupportedLanguage
    let text: String
    let isStable: Bool
}
