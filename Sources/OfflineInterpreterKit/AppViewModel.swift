import Foundation
import Combine
import AppKit
import UniformTypeIdentifiers
@preconcurrency import Translation

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
    @Published public private(set) var translationPreparationRequest: TranslationPreparationRequest?
    @Published public private(set) var preparingTranslationPair: TranslationPair?
    @Published public private(set) var isPreparingTranslationResources = false

    private let launchDemoSnapshot: Bool

    private let readinessService = OfflineReadinessService()
    private let lexiconOverlay = LexiconOverlay()
    private let playbackService = SpeechPlaybackService()
    private lazy var translationPipeline = TranslationPipeline(lexiconOverlay: lexiconOverlay)
    private lazy var speechRecognition = SpeechRecognitionManager(lexiconOverlay: lexiconOverlay)

    private var activeCapture: AudioCaptureController?
    private var translationTask: Task<Void, Never>?
    private var silenceWatchdogTask: Task<Void, Never>?
    private var recognitionHealthTask: Task<Void, Never>?
    private var currentRevision = 0
    private var currentUtteranceStartedAt: Date?
    private var lastSpeechUpdate: SpeechPipelineUpdate?
    private var lastScheduledSignature: ScheduledSignature?
    private var hasAttemptedAutoStart = false
    private var cancellables: Set<AnyCancellable> = []
    private let maxStoredSegments = 360
    private let maxDisplayedSegments = 72
    private var shouldResumeStartAfterTranslationPreparation = false
    private let minimumDiskSpaceForTranslationDownloadBytes: Int64 = 1_000_000_000
    private var lastTranscriptMutationAt = Date()
    private var lastPipelineRecoveryAt: Date?
    private var committedSourcePrefix = ""

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
        let combined = TranscriptSegmentReducer.composeDisplaySegments(stableSegments: segments, liveSegment: liveSegment)
        if combined.count > maxDisplayedSegments {
            return Array(combined.suffix(maxDisplayedSegments))
        }
        return combined
    }

    public var compactStatusText: String {
        if let preparationStatusText {
            return preparationStatusText
        }
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
            return "\(selectedSourceLanguage.displayName) -> \(targetLanguage.displayName)：系统支持该语言对，首次使用会提示下载离线翻译资源。"
        case .unsupported:
            return "\(selectedSourceLanguage.displayName) -> \(targetLanguage.displayName)：当前系统不支持该语言对。"
        case .unknown:
            return "\(selectedSourceLanguage.displayName) -> \(targetLanguage.displayName)：正在检查系统翻译能力。"
        }
    }

    public var startButtonTitle: String {
        if isPreparingTranslationResources {
            return "准备资源中…"
        }
        return isRunning ? "停止" : "开始"
    }

    public var canTriggerPrimaryAction: Bool {
        !isPreparingTranslationResources || isRunning
    }

    public var preparationStatusText: String? {
        guard isPreparingTranslationResources, let pair = preparingTranslationPair else { return nil }
        return "正在为 \(pair.source.displayName) -> \(pair.target.displayName) 准备离线翻译资源。macOS 不提供下载百分比；若弹出系统确认，请选择允许。"
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

    public var needsManualTranslationDownload: Bool {
        let pair = TranslationPair(source: selectedSourceLanguage, target: targetLanguage)
        return readinessReport?.translationAvailability[pair] == .supported
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
        } else if report.translationAvailability[TranslationPair(source: selectedSourceLanguage, target: targetLanguage)] == .supported {
            statusMessage = "\(selectedSourceLanguage.displayName) 到 \(targetLanguage.displayName) 首次使用会提示下载离线翻译资源。"
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
            await refreshReadiness()
            if isRunning {
                await restartPipeline(resetSegments: false)
            }
        }
    }

    public func handleLanguageModeChanged() {
        guard !launchDemoSnapshot else { return }
        Task {
            cancelTranslationPreparation()
            await refreshReadiness()
            if isRunning {
                await restartPipeline(resetSegments: false)
            }
        }
    }

    public func handleTargetLanguageChanged() {
        guard !launchDemoSnapshot else { return }
        Task {
            cancelTranslationPreparation()
            await refreshReadiness()
            let pair = TranslationPair(source: selectedSourceLanguage, target: targetLanguage)
            if readinessReport?.translationAvailability[pair] == .supported {
                statusMessage = "切换到 \(selectedSourceLanguage.displayName) -> \(targetLanguage.displayName) 后，点击开始时系统会提示下载离线翻译资源。"
                return
            }
            if let lastSpeechUpdate {
                currentRevision += 1
                scheduleTranslationPlan(for: lastSpeechUpdate)
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

    public func openTranslationLanguageSettings() {
        readinessService.openLanguageRegionSettings()
    }

    public func dictionaryDefinition(for token: String) -> String? {
        lexiconOverlay.dictionaryDefinition(for: token)
    }

    public func dismissError() {
        errorMessage = nil
    }

    public func completeTranslationPreparation() {
        let shouldResume = shouldResumeStartAfterTranslationPreparation
        shouldResumeStartAfterTranslationPreparation = false
        let pair = preparingTranslationPair ?? TranslationPair(source: selectedSourceLanguage, target: targetLanguage)

        Task {
            statusMessage = "正在确认 \(pair.source.displayName) -> \(pair.target.displayName) 的离线翻译资源是否已就绪。"
            let availability = await waitForInstalledTranslation(for: pair, timeout: 20)
            resetTranslationPreparationState()
            if availability == .installed {
                statusMessage = "\(pair.source.displayName) 到 \(pair.target.displayName) 的离线翻译资源已就绪。"
                if shouldResume, !isRunning {
                    await start()
                }
            } else if availability == .supported {
                runState = .idle
                statusMessage = "\(pair.source.displayName) 到 \(pair.target.displayName) 的离线翻译资源仍未完成下载。请允许系统下载后再点开始。"
            } else {
                runState = .error
                errorMessage = "\(pair.source.displayName) 到 \(pair.target.displayName) 的离线翻译资源仍不可用。"
            }
        }
    }

    public func failTranslationPreparation(_ error: Error) {
        shouldResumeStartAfterTranslationPreparation = false
        resetTranslationPreparationState()
        present(error: error)
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
        markTranscriptChanged()
    }

    public func clearSubtitles() {
        segments.removeAll()
        liveSegment = nil
        currentUtteranceStartedAt = nil
        lastSpeechUpdate = nil
        lastScheduledSignature = nil
        committedSourcePrefix = ""
        markTranscriptChanged()
        statusMessage = "已清空当前字幕。"
    }

    public func exportTranscript(as format: TranscriptExportFormat) {
        let exportSegments = TranscriptSegmentReducer.coalesce(segments)
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

        let pair = TranslationPair(source: selectedSourceLanguage, target: targetLanguage)
        if readinessReport?.translationAvailability[pair] == .supported {
            let message = manualTranslationDownloadMessage(for: pair)
            shouldResumeStartAfterTranslationPreparation = false
            resetTranslationPreparationState()
            errorMessage = message
            statusMessage = message
            runState = .blocked
            return
        }

        do {
            try await activateStreamingPipeline(markRunning: true)
            startRecognitionHealthMonitor()
        } catch {
            present(error: error)
            await stop()
        }
    }

    private func stop() async {
        translationTask?.cancel()
        silenceWatchdogTask?.cancel()
        recognitionHealthTask?.cancel()
        speechRecognition.stop()
        await activeCapture?.stop()
        activeCapture = nil
        playbackService.stop()
        isRunning = false
        liveSegment = nil
        currentUtteranceStartedAt = nil
        lastSpeechUpdate = nil
        lastScheduledSignature = nil
        committedSourcePrefix = ""
        markTranscriptChanged()
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

    private func startRecognitionHealthMonitor() {
        recognitionHealthTask?.cancel()
        recognitionHealthTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }

                guard let self else { return }
                guard self.isRunning else { continue }

                do {
                    let now = Date()
                    let snapshot = self.speechRecognition.healthSnapshot(now: now)
                    let recovered = try self.speechRecognition.recoverIfStalled(mode: self.languageMode, now: now)
                    if recovered {
                        await MainActor.run {
                            self.statusMessage = "识别链路已自动恢复。"
                        }
                        continue
                    }

                    let transcriptStale = now.timeIntervalSince(self.lastTranscriptMutationAt) >= 6
                    let pipelineRecoveryCooldownElapsed = self.lastPipelineRecoveryAt.map { now.timeIntervalSince($0) >= 8 } ?? true
                    if snapshot.hasRecentAudioInput,
                       let recognitionUpdateAge = snapshot.recognitionUpdateAge,
                       recognitionUpdateAge >= 8,
                       transcriptStale,
                       pipelineRecoveryCooldownElapsed {
                        self.lastPipelineRecoveryAt = now
                        await self.recoverStreamingPipeline()
                    }
                } catch {
                    await MainActor.run {
                        self.present(error: error)
                    }
                }
            }
        }
    }

    private func prepareForOverlayMode() async {
        guard !launchDemoSnapshot else { return }
        await refreshReadiness()
        hasAttemptedAutoStart = true
    }

    private func handleAppBecameActive() async {
        guard !launchDemoSnapshot else { return }
        await refreshReadiness()
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
        scheduleTranslationPlan(for: update)
        scheduleSilenceWatchdog(after: silenceWatchdogDelay(for: update), from: update)
    }

    private func scheduleTranslationPlan(for update: SpeechPipelineUpdate) {
        let plan = makeTranslationPlan(from: update)
        let revision = currentRevision
        translationTask?.cancel()
        let signatureText = [
            plan.stableCommittedText ?? "",
            plan.liveUpdate?.text ?? ""
        ]
        .joined(separator: "|")
        lastScheduledSignature = ScheduledSignature(
            sourceLanguage: update.sourceLanguage,
            text: signatureText,
            isStable: update.isStable
        )
        translationTask = Task { [weak self] in
            do {
                let debounceSource = plan.liveUpdate ?? update
                try await Task.sleep(for: self?.translationDebounce(for: debounceSource, isStable: update.isStable) ?? .milliseconds(80))
                guard !Task.isCancelled else { return }
                await self?.execute(plan: plan, revision: revision, originalUpdate: update)
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
                    self.scheduleTranslationPlan(for: forcedStableUpdate)
                }
            } catch {
                return
            }
        }
    }

    private func execute(
        plan: TranslationPlan,
        revision: Int,
        originalUpdate: SpeechPipelineUpdate
    ) async {
        if let committedPrefix = plan.newCommittedPrefix {
            committedSourcePrefix = committedPrefix
        }

        if let stableCommittedText = plan.stableCommittedText {
            let stableUpdate = SpeechPipelineUpdate(
                sourceLanguage: originalUpdate.sourceLanguage,
                text: stableCommittedText,
                confidence: originalUpdate.confidence,
                isStable: true,
                receivedAt: originalUpdate.receivedAt
            )
            await performTranslation(
                for: stableUpdate,
                revision: revision,
                isStable: true,
                preserveStreamingState: !originalUpdate.isStable
            )
        }

        if originalUpdate.isStable {
            committedSourcePrefix = ""
        }

        if let liveUpdate = plan.liveUpdate {
            await performTranslation(for: liveUpdate, revision: revision, isStable: false)
        } else if !originalUpdate.isStable {
            liveSegment = nil
            markTranscriptChanged()
        }
    }

    private func performTranslation(
        for update: SpeechPipelineUpdate,
        revision: Int,
        isStable: Bool,
        preserveStreamingState: Bool = false
    ) async {
        guard !update.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let pair = TranslationPair(source: update.sourceLanguage, target: targetLanguage)
        if readinessReport?.translationAvailability[pair] == .supported {
            let message = manualTranslationDownloadMessage(for: pair)
            shouldResumeStartAfterTranslationPreparation = false
            resetTranslationPreparationState()
            errorMessage = message
            statusMessage = message
            runState = .blocked
            return
        }
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
                id: isStable ? UUID() : (liveSegment?.id ?? UUID()),
                sourceLanguage: result.sourceLanguage,
                targetLanguage: result.targetLanguage,
                sourceText: result.sourceText,
                translatedText: result.translatedText,
                isStable: isStable,
                startedAt: startedAt,
                updatedAt: result.completedAt
            )

            if isStable {
                commitStableSegment(segment)
                liveSegment = nil
                if !preserveStreamingState {
                    currentUtteranceStartedAt = nil
                    lastSpeechUpdate = nil
                    committedSourcePrefix = ""
                }
                statusMessage = "已完成一段离线翻译。"
                markTranscriptChanged()
                if speakTranslations && !preserveStreamingState {
                    playbackService.speak(result.translatedText, language: result.targetLanguage)
                    runState = .speaking
                } else if preserveStreamingState {
                    runState = .translating
                } else {
                    runState = .listening
                }
            } else {
                liveSegment = segment
                runState = .translating
                statusMessage = "正在滚动翻译。"
                markTranscriptChanged()
            }
        } catch {
            present(error: error)
        }
    }

    private func translationDebounce(for update: SpeechPipelineUpdate, isStable: Bool) -> Duration {
        let multiplier = recognitionSpeedMultiplier(for: update.sourceLanguage)
        if isStable {
            return scaledDuration(milliseconds: 8, multiplier: multiplier)
        }

        let punctuation = CharacterSet(charactersIn: ".!?。！？,，;；、")
        let lastScalar = update.text.unicodeScalars.last
        if let lastScalar, punctuation.contains(lastScalar) {
            return scaledDuration(milliseconds: 20, multiplier: multiplier)
        }

        if update.text.count < 14 {
            return scaledDuration(milliseconds: 28, multiplier: multiplier)
        }

        if update.text.count < 42 {
            return scaledDuration(milliseconds: 42, multiplier: multiplier)
        }

        return scaledDuration(milliseconds: 56, multiplier: multiplier)
    }

    private func silenceWatchdogDelay(for update: SpeechPipelineUpdate) -> Double {
        let multiplier = stabilityDelayMultiplier(for: update.sourceLanguage)
        let punctuation = CharacterSet(charactersIn: ".!?。！？,，;；、")
        if let lastScalar = update.text.unicodeScalars.last, punctuation.contains(lastScalar) {
            return max(0.14, 0.18 * multiplier)
        }
        if update.text.count < 12 {
            return max(0.16, 0.22 * multiplier)
        }
        if update.text.count < 24 {
            return max(0.2, 0.28 * multiplier)
        }
        return max(0.24, 0.34 * multiplier)
    }

    private func recognitionSpeedMultiplier(for language: SupportedLanguage) -> Double {
        switch language {
        case .ru, .it, .ja, .fr, .de, .es, .ko:
            return 0.72
        case .zhHans, .en, .th:
            return 1.0
        }
    }

    private func stabilityDelayMultiplier(for language: SupportedLanguage) -> Double {
        switch language {
        case .ru, .it, .ja, .fr, .de, .es, .ko:
            return 2.0
        case .zhHans, .en, .th:
            return 1.0
        }
    }

    private func scaledDuration(milliseconds: Int, multiplier: Double) -> Duration {
        let adjusted = max(Int((Double(milliseconds) * multiplier).rounded()), 6)
        return .milliseconds(adjusted)
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
        case (.ru, .zhHans):
            return [
                ("Сейчас мы тестируем перевод с русского на китайский в реальном времени.", "现在正在测试俄语到中文的实时翻译。"),
                ("Приложение может одновременно показывать оригинал и перевод в двух колонках.", "应用可以同时用双栏显示原文和译文。"),
                ("После переключения языка запись и экспорт остаются доступными.", "切换语言后，字幕记录和导出功能仍然可用。")
            ]
        case (.it, .zhHans):
            return [
                ("Stiamo testando la traduzione simultanea dall'italiano al cinese.", "现在正在测试意大利语到中文的实时翻译。"),
                ("L'app supporta sia l'audio di sistema sia il microfono.", "这个应用同时支持系统音频和麦克风输入。"),
                ("Puoi ridimensionare la finestra senza interrompere i sottotitoli.", "调整窗口大小时，字幕会继续正常显示。")
            ]
        case (.zhHans, .ru):
            return [
                ("现在开始测试中文到俄文的同声翻译。", "Сейчас мы тестируем синхронный перевод с китайского на русский."),
                ("你可以一边播放视频，一边查看双栏字幕。", "Вы можете одновременно воспроизводить видео и читать двуколоночные субтитры."),
                ("目标是尽量保持低延迟和稳定输出。", "Цель — сохранить минимальную задержку и стабильный вывод.")
            ]
        case (.zhHans, .it):
            return [
                ("现在开始测试中文到意大利文的同声翻译。", "Ora stiamo testando la traduzione simultanea dal cinese all'italiano."),
                ("切换语言后，界面和导出内容都会同步更新。", "Dopo il cambio lingua, anche interfaccia ed esportazione si aggiornano subito."),
                ("目标是尽量保持低延迟和稳定输出。", "L'obiettivo è mantenere bassa la latenza e un output stabile.")
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

        if nsError.domain == "Translation.TranslationError",
           nsError.code == 1,
           (nsError.localizedFailureReason?.localizedCaseInsensitiveContains("downloaded on-device") == true
            || nsError.localizedDescription.localizedCaseInsensitiveContains("unable to translate")) {
            let pair = TranslationPair(source: selectedSourceLanguage, target: targetLanguage)
            let pairMessage = manualTranslationDownloadMessage(for: pair)
            resetTranslationPreparationState()
            errorMessage = pairMessage
            statusMessage = pairMessage
            runState = .blocked
            return
        }

        errorMessage = error.localizedDescription
        statusMessage = error.localizedDescription
        runState = .error
    }

    private func beginTranslationPreparation(
        for pair: TranslationPair,
        autoResumeStart: Bool,
        status: String
    ) {
        if let availableDiskSpace = readinessService.availableDiskSpaceBytes(),
           availableDiskSpace < minimumDiskSpaceForTranslationDownloadBytes {
            let freeMB = max(availableDiskSpace / 1_000_000, 0)
            let message = "磁盘可用空间不足，当前仅剩约 \(freeMB) MB，系统无法下载 \(pair.source.displayName) -> \(pair.target.displayName) 的离线翻译资源。请先释放至少 1 GB 空间后再试。"
            shouldResumeStartAfterTranslationPreparation = false
            errorMessage = message
            statusMessage = message
            runState = .error
            resetTranslationPreparationState()
            return
        }

        if autoResumeStart {
            shouldResumeStartAfterTranslationPreparation = true
        }
        preparingTranslationPair = pair
        isPreparingTranslationResources = true
        translationPreparationRequest = TranslationPreparationRequest(pair: pair)
        runState = .checkingReadiness
        statusMessage = status
    }

    private func resetTranslationPreparationState() {
        translationPreparationRequest = nil
        preparingTranslationPair = nil
        isPreparingTranslationResources = false
    }

    private func cancelTranslationPreparation() {
        shouldResumeStartAfterTranslationPreparation = false
        resetTranslationPreparationState()
    }

    private func waitForInstalledTranslation(for pair: TranslationPair, timeout: TimeInterval) async -> AssetAvailability {
        let deadline = Date().addingTimeInterval(timeout)
        var availability: AssetAvailability = .unknown

        repeat {
            availability = await readinessService.translationAvailability(for: pair)
            if availability != .supported {
                await refreshReadiness()
                return availability
            }

            try? await Task.sleep(for: .milliseconds(500))
        } while Date() < deadline

        await refreshReadiness()
        return availability
    }

    private func manualTranslationDownloadMessage(for pair: TranslationPair) -> String {
        "\(pair.source.displayName) 到 \(pair.target.displayName) 当前仅处于“系统支持”状态，但离线翻译资源尚未安装。请前往“系统设置 -> 通用 -> 语言与地区 -> 翻译语言”手动下载后再试。"
    }

    private func effectiveTranslationUpdate(
        from update: SpeechPipelineUpdate,
        isStable: Bool
    ) -> SpeechPipelineUpdate {
        let trimmedText = trimmedLiveText(for: update, isStable: isStable)
        guard trimmedText != update.text else { return update }

        return SpeechPipelineUpdate(
            sourceLanguage: update.sourceLanguage,
            text: trimmedText,
            confidence: update.confidence,
            isStable: update.isStable,
            receivedAt: update.receivedAt
        )
    }

    private func trimmedLiveText(for update: SpeechPipelineUpdate, isStable: Bool) -> String {
        let trimmed = uncommittedText(from: update.text)
        guard !trimmed.isEmpty else { return update.text }

        guard !isStable else { return trimmed }

        let candidate = trimmed

        let liveWindow = maxLiveTranslationWindow(for: update.sourceLanguage)
        guard candidate.count > liveWindow else { return candidate }

        let suffixIndex = candidate.index(candidate.endIndex, offsetBy: -liveWindow)
        let suffix = String(candidate[suffixIndex...])
        return anchoredWindow(in: suffix)
    }

    private func maxLiveTranslationWindow(for language: SupportedLanguage) -> Int {
        switch language {
        case .ru, .it, .ja, .fr, .de, .es, .ko:
            return 150
        case .zhHans, .en, .th:
            return 180
        }
    }

    private func anchoredWindow(in text: String) -> String {
        let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        let unicodeScalars = Array(text.unicodeScalars)
        guard unicodeScalars.count > 48 else { return text }

        if let splitOffset = unicodeScalars.indices.first(where: { index in
            index >= 24 && separators.contains(unicodeScalars[index])
        }) {
            let scalarView = String.UnicodeScalarView(unicodeScalars[splitOffset...])
            let anchored = String(scalarView).trimmingCharacters(in: .whitespacesAndNewlines)
            if anchored.count >= 24 {
                return anchored
            }
        }

        return text
    }

    private func makeTranslationPlan(from update: SpeechPipelineUpdate) -> TranslationPlan {
        if update.isStable {
            let stableText = effectiveTranslationUpdate(from: update, isStable: true).text
            return TranslationPlan(
                stableCommittedText: stableText.isEmpty ? nil : stableText,
                liveUpdate: nil,
                newCommittedPrefix: nil
            )
        }

        if let commit = autoCommitChunk(from: update) {
            let liveText = commit.remainingText
            let liveUpdate: SpeechPipelineUpdate?
            if liveText.isEmpty {
                liveUpdate = nil
            } else {
                liveUpdate = SpeechPipelineUpdate(
                    sourceLanguage: update.sourceLanguage,
                    text: liveText,
                    confidence: update.confidence,
                    isStable: false,
                    receivedAt: update.receivedAt
                )
            }

            return TranslationPlan(
                stableCommittedText: commit.committedText,
                liveUpdate: liveUpdate,
                newCommittedPrefix: commit.newCommittedPrefix
            )
        }

        let liveUpdate = effectiveTranslationUpdate(from: update, isStable: false)
        return TranslationPlan(
            stableCommittedText: nil,
            liveUpdate: liveUpdate.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : liveUpdate,
            newCommittedPrefix: nil
        )
    }

    private func autoCommitChunk(from update: SpeechPipelineUpdate) -> AutoCommittedChunk? {
        let normalizedFullText = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedFullText.isEmpty else { return nil }

        let uncommittedRaw = uncommittedRawText(from: update.text)
        let uncommitted = uncommittedRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !uncommitted.isEmpty else { return nil }

        let commitBoundary = commitBoundaryIndex(in: uncommittedRaw, language: update.sourceLanguage)
        guard let boundary = commitBoundary else { return nil }

        let committedRaw = String(uncommittedRaw[..<boundary])
        let committedText = committedRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        let remainingText = String(uncommittedRaw[boundary...]).trimmingCharacters(in: .whitespacesAndNewlines)

        guard committedText.count >= 16 else { return nil }

        let newCommittedPrefix = committedSourcePrefix + committedRaw
        return AutoCommittedChunk(
            committedText: committedText,
            remainingText: remainingText,
            newCommittedPrefix: newCommittedPrefix
        )
    }

    private func uncommittedText(from recognizedText: String) -> String {
        uncommittedRawText(from: recognizedText).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func uncommittedRawText(from recognizedText: String) -> String {
        guard !committedSourcePrefix.isEmpty else { return recognizedText }
        guard recognizedText.hasPrefix(committedSourcePrefix) else { return recognizedText }
        return String(recognizedText.dropFirst(committedSourcePrefix.count))
    }

    private func commitBoundaryIndex(
        in rawText: String,
        language: SupportedLanguage
    ) -> String.Index? {
        let punctuationScalars = CharacterSet(charactersIn: ".!?。！？;；")
        let prefersPunctuationBoundary = language.addsPunctuationDuringRecognition
        let minimumTailCount = prefersPunctuationBoundary ? 18 : 10
        let minimumCommittedCount = prefersPunctuationBoundary ? 18 : 14

        var lastPunctuationBoundary: String.Index?
        for index in rawText.indices {
            let next = rawText.index(after: index)
            guard let scalar = rawText[index].unicodeScalars.first else { continue }
            if punctuationScalars.contains(scalar) {
                let committedCount = rawText[..<next].trimmingCharacters(in: .whitespacesAndNewlines).count
                let remainingCount = rawText[next...].trimmingCharacters(in: .whitespacesAndNewlines).count
                if committedCount >= minimumCommittedCount && remainingCount >= minimumTailCount {
                    lastPunctuationBoundary = next
                }
            }
        }
        if let lastPunctuationBoundary {
            return lastPunctuationBoundary
        }

        let hardWindow = prefersPunctuationBoundary ? (maxLiveTranslationWindow(for: language) + 40) : 72
        guard rawText.count >= hardWindow else { return nil }

        let splitTarget = prefersPunctuationBoundary ? (maxLiveTranslationWindow(for: language) - 20) : 54
        let anchorOffset = min(max(splitTarget, 32), rawText.count - minimumTailCount)
        let anchorIndex = rawText.index(rawText.startIndex, offsetBy: anchorOffset)
        let suffix = rawText[anchorIndex...]
        if let whitespaceBoundary = suffix.firstIndex(where: { $0.isWhitespace }) {
            let committedCount = rawText[..<whitespaceBoundary].trimmingCharacters(in: .whitespacesAndNewlines).count
            let remainingCount = rawText[whitespaceBoundary...].trimmingCharacters(in: .whitespacesAndNewlines).count
            if committedCount >= minimumCommittedCount && remainingCount >= minimumTailCount {
                return whitespaceBoundary
            }
        }

        return nil
    }

    private func markTranscriptChanged() {
        transcriptRevision += 1
        lastTranscriptMutationAt = .now
    }

    private func activateStreamingPipeline(markRunning: Bool) async throws {
        let capture = makeAudioCapture()
        try speechRecognition.start(mode: languageMode)
        await translationPipeline.prepare(source: selectedSourceLanguage, target: targetLanguage)
        try await capture.start()
        activeCapture = capture
        if markRunning {
            isRunning = true
        }
        runState = .listening
        statusMessage = audioSource == .microphone ? "正在监听麦克风。" : "正在监听系统音频。"
    }

    private func makeAudioCapture() -> AudioCaptureController {
        let capture: AudioCaptureController = switch audioSource {
        case .microphone:
            MicrophoneAudioCapture()
        case .systemAudio:
            SystemAudioCapture()
        }

        capture.onPCMBuffer = { [weak self] buffer in
            self?.speechRecognition.appendPCMBuffer(buffer)
        }
        capture.onSampleBuffer = { [weak self] sampleBuffer in
            self?.speechRecognition.appendSampleBuffer(sampleBuffer)
        }
        return capture
    }

    private func recoverStreamingPipeline() async {
        guard isRunning else { return }

        translationTask?.cancel()
        silenceWatchdogTask?.cancel()
        playbackService.stop()
        speechRecognition.stop()
        await activeCapture?.stop()
        activeCapture = nil
        liveSegment = nil
        currentUtteranceStartedAt = nil
        lastSpeechUpdate = nil
        lastScheduledSignature = nil
        committedSourcePrefix = ""
        markTranscriptChanged()

        do {
            try await activateStreamingPipeline(markRunning: false)
            statusMessage = "音频链路已自动恢复。"
        } catch {
            present(error: error)
        }
    }

    private func commitStableSegment(_ segment: TranslationSegment) {
        if let last = segments.last,
           TranscriptSegmentReducer.shouldMerge(last, with: segment) {
            segments[segments.count - 1] = TranslationSegment(
                id: last.id,
                sourceLanguage: segment.sourceLanguage,
                targetLanguage: segment.targetLanguage,
                sourceText: segment.sourceText,
                translatedText: segment.translatedText,
                isStable: true,
                startedAt: last.startedAt,
                updatedAt: segment.updatedAt
            )
        } else {
            segments.append(segment)
            if segments.count > maxStoredSegments {
                segments = Array(segments.suffix(maxStoredSegments))
            }
        }
    }
}

private struct ScheduledSignature: Equatable {
    let sourceLanguage: SupportedLanguage
    let text: String
    let isStable: Bool
}

private struct TranslationPlan {
    let stableCommittedText: String?
    let liveUpdate: SpeechPipelineUpdate?
    let newCommittedPrefix: String?
}

private struct AutoCommittedChunk {
    let committedText: String
    let remainingText: String
    let newCommittedPrefix: String
}

struct TranscriptSegmentReducer {
    static func composeDisplaySegments(
        stableSegments: [TranslationSegment],
        liveSegment: TranslationSegment?
    ) -> [TranslationSegment] {
        var reduced = coalesce(stableSegments)

        guard let liveSegment else { return reduced }

        if let index = reduced.firstIndex(where: { $0.id == liveSegment.id && !$0.isStable }) {
            reduced[index] = liveSegment
        } else {
            if reduced.contains(where: { $0.id == liveSegment.id }) {
                reduced.append(
                    TranslationSegment(
                        sourceLanguage: liveSegment.sourceLanguage,
                        targetLanguage: liveSegment.targetLanguage,
                        sourceText: liveSegment.sourceText,
                        translatedText: liveSegment.translatedText,
                        isStable: false,
                        startedAt: liveSegment.startedAt,
                        updatedAt: liveSegment.updatedAt
                    )
                )
            } else {
                reduced.append(liveSegment)
            }
        }

        return reduced
    }

    static func coalesce(_ segments: [TranslationSegment]) -> [TranslationSegment] {
        guard !segments.isEmpty else { return [] }

        var reduced: [TranslationSegment] = []
        reduced.reserveCapacity(segments.count)

        for segment in segments {
            if let last = reduced.last, shouldMerge(last, with: segment) {
                reduced[reduced.count - 1] = merged(lhs: last, rhs: segment)
            } else {
                reduced.append(segment)
            }
        }

        return reduced
    }

    static func shouldMerge(_ lhs: TranslationSegment, with rhs: TranslationSegment) -> Bool {
        guard lhs.sourceLanguage == rhs.sourceLanguage,
              lhs.targetLanguage == rhs.targetLanguage else {
            return false
        }

        let recentGap = rhs.updatedAt.timeIntervalSince(lhs.updatedAt) <= 18
        guard recentGap else { return false }

        let lhsSource = normalized(lhs.sourceText)
        let rhsSource = normalized(rhs.sourceText)
        let lhsTranslation = normalized(lhs.translatedText)
        let rhsTranslation = normalized(rhs.translatedText)

        guard !lhsSource.isEmpty, !rhsSource.isEmpty else { return false }
        guard manageableGrowth(lhsSource, rhsSource) else { return false }

        return overlapsStrongly(lhsSource, rhsSource)
            || (min(lhsSource.count, rhsSource.count) < 12
                && !lhsTranslation.isEmpty
                && !rhsTranslation.isEmpty
                && overlapsStrongly(lhsTranslation, rhsTranslation))
    }

    private static func merged(lhs: TranslationSegment, rhs: TranslationSegment) -> TranslationSegment {
        TranslationSegment(
            id: lhs.id,
            sourceLanguage: rhs.sourceLanguage,
            targetLanguage: rhs.targetLanguage,
            sourceText: rhs.sourceText,
            translatedText: rhs.translatedText,
            isStable: rhs.isStable,
            startedAt: lhs.startedAt,
            updatedAt: rhs.updatedAt
        )
    }

    private static func normalized(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func overlapsStrongly(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs || lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs) {
            return true
        }

        let minCount = min(lhs.count, rhs.count)
        guard minCount >= 12 else { return false }

        let prefix = commonPrefixLength(lhs, rhs)
        if Double(prefix) / Double(minCount) >= 0.9 {
            return true
        }

        let overlap = suffixPrefixOverlap(lhs, rhs)
        return Double(overlap) / Double(minCount) >= 0.9
    }

    private static func manageableGrowth(_ lhs: String, _ rhs: String) -> Bool {
        let shorter = min(lhs.count, rhs.count)
        let longer = max(lhs.count, rhs.count)
        let growth = longer - shorter
        return growth <= max(72, Int(Double(shorter) * 0.85))
    }

    private static func commonPrefixLength(_ lhs: String, _ rhs: String) -> Int {
        let lhsChars = Array(lhs)
        let rhsChars = Array(rhs)
        var count = 0

        for (left, right) in zip(lhsChars, rhsChars) {
            guard left == right else { break }
            count += 1
        }

        return count
    }

    private static func suffixPrefixOverlap(_ lhs: String, _ rhs: String) -> Int {
        let lhsChars = Array(lhs)
        let rhsChars = Array(rhs)
        let maxOverlap = min(lhsChars.count, rhsChars.count)

        guard maxOverlap > 0 else { return 0 }

        for length in stride(from: maxOverlap, through: 1, by: -1) {
            if Array(lhsChars.suffix(length)) == Array(rhsChars.prefix(length)) {
                return length
            }
            if Array(rhsChars.suffix(length)) == Array(lhsChars.prefix(length)) {
                return length
            }
        }

        return 0
    }
}
