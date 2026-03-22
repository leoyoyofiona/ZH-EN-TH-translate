import Foundation

public enum AudioSourceKind: String, CaseIterable, Identifiable, Sendable {
    case microphone
    case systemAudio

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .microphone: return "麦克风"
        case .systemAudio: return "系统音频"
        }
    }
}

public enum SupportedLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
    case zhHans = "zh-Hans"
    case en = "en"
    case th = "th"
    case ru = "ru"
    case it = "it"
    case ja = "ja"
    case fr = "fr"
    case de = "de"
    case es = "es"
    case ko = "ko"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .zhHans: return "中文"
        case .en: return "英文"
        case .th: return "泰文"
        case .ru: return "俄文"
        case .it: return "意大利文"
        case .ja: return "日文"
        case .fr: return "法文"
        case .de: return "德文"
        case .es: return "西班牙文"
        case .ko: return "韩文"
        }
    }

    public var localeIdentifier: String {
        switch self {
        case .zhHans: return "zh-CN"
        case .en: return "en-US"
        case .th: return "th-TH"
        case .ru: return "ru-RU"
        case .it: return "it-IT"
        case .ja: return "ja-JP"
        case .fr: return "fr-FR"
        case .de: return "de-DE"
        case .es: return "es-ES"
        case .ko: return "ko-KR"
        }
    }

    public var translationIdentifier: String {
        rawValue
    }

    public var localeLanguage: Locale.Language {
        Locale.Language(identifier: translationIdentifier)
    }

    public var defaultVoiceIdentifier: String {
        switch self {
        case .zhHans: return "com.apple.voice.compact.zh-CN.Tingting"
        case .en: return "com.apple.voice.compact.en-US.Samantha"
        case .th: return "com.apple.voice.compact.th-TH.Kanya"
        case .ru: return "com.apple.voice.compact.ru-RU.Milena"
        case .it: return "com.apple.voice.compact.it-IT.Alice"
        case .ja: return "com.apple.voice.compact.ja-JP.Kyoko"
        case .fr: return "com.apple.voice.compact.fr-FR.Thomas"
        case .de: return "com.apple.voice.compact.de-DE.Anna"
        case .es: return "com.apple.voice.compact.es-ES.Monica"
        case .ko: return "com.apple.voice.compact.ko-KR.Yuna"
        }
    }

    public var fallbackVoiceName: String {
        switch self {
        case .zhHans: return "Tingting"
        case .en: return "Samantha"
        case .th: return "Kanya"
        case .ru: return "Milena"
        case .it: return "Alice"
        case .ja: return "Kyoko"
        case .fr: return "Thomas"
        case .de: return "Anna"
        case .es: return "Monica"
        case .ko: return "Yuna"
        }
    }

    public var bcP47Tag: String {
        localeIdentifier
    }

    public var addsPunctuationDuringRecognition: Bool {
        switch self {
        case .zhHans, .en, .th:
            return true
        case .ru, .it, .ja, .fr, .de, .es, .ko:
            return false
        }
    }

    public func scriptScore(for text: String) -> Double {
        guard !text.isEmpty else { return 0 }

        let scalars = Array(text.unicodeScalars)
        guard !scalars.isEmpty else { return 0 }

        let matched: Int = scalars.reduce(into: 0) { partialResult, scalar in
            let value = scalar.value
            switch self {
            case .zhHans:
                if (0x4E00...0x9FFF).contains(value) || (0x3400...0x4DBF).contains(value) {
                    partialResult += 1
                }
            case .en:
                if (0x0041...0x005A).contains(value) || (0x0061...0x007A).contains(value) {
                    partialResult += 1
                }
            case .th:
                if (0x0E00...0x0E7F).contains(value) {
                    partialResult += 1
                }
            case .ru:
                if (0x0400...0x04FF).contains(value) || (0x0500...0x052F).contains(value) {
                    partialResult += 1
                }
            case .ja:
                if (0x3040...0x309F).contains(value) || (0x30A0...0x30FF).contains(value) || (0x4E00...0x9FFF).contains(value) {
                    partialResult += 1
                }
            case .it, .fr, .de, .es:
                if (0x0041...0x005A).contains(value)
                    || (0x0061...0x007A).contains(value)
                    || (0x00C0...0x00FF).contains(value) {
                    partialResult += 1
                }
            case .ko:
                if (0x1100...0x11FF).contains(value) || (0x3130...0x318F).contains(value) || (0xAC00...0xD7AF).contains(value) {
                    partialResult += 1
                }
            }
        }

        return Double(matched) / Double(scalars.count)
    }
}

public enum LanguageSelectionMode: Hashable, Sendable {
    case auto
    case manual(SupportedLanguage)

    public var displayName: String {
        switch self {
        case .auto:
            return "自动"
        case .manual(let language):
            return language.displayName
        }
    }

    public var manuallySelectedLanguage: SupportedLanguage? {
        if case .manual(let language) = self {
            return language
        }
        return nil
    }
}

public enum PipelineRunState: String, Sendable {
    case idle
    case checkingReadiness
    case blocked
    case listening
    case translating
    case speaking
    case error
}

public enum SubtitleColorStyle: String, CaseIterable, Identifiable, Sendable {
    case system
    case black
    case white
    case yellow
    case cyan
    case magenta
    case red
    case orange
    case green
    case blue
    case indigo

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return "跟随系统"
        case .black: return "黑色"
        case .white: return "白色"
        case .yellow: return "黄色"
        case .cyan: return "青色"
        case .magenta: return "粉色"
        case .red: return "红色"
        case .orange: return "橙色"
        case .green: return "绿色"
        case .blue: return "蓝色"
        case .indigo: return "靛蓝"
        }
    }
}

public enum TranscriptExportFormat: String, CaseIterable, Identifiable, Sendable {
    case txt
    case markdown
    case word

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .txt: return "TXT"
        case .markdown: return "Markdown"
        case .word: return "Word"
        }
    }

    public var fileExtension: String {
        switch self {
        case .txt: return "txt"
        case .markdown: return "md"
        case .word: return "docx"
        }
    }
}

public struct TranslationSegment: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let sourceLanguage: SupportedLanguage
    public let targetLanguage: SupportedLanguage
    public let sourceText: String
    public let translatedText: String
    public let isStable: Bool
    public let startedAt: Date
    public let updatedAt: Date

    public init(
        id: UUID = UUID(),
        sourceLanguage: SupportedLanguage,
        targetLanguage: SupportedLanguage,
        sourceText: String,
        translatedText: String,
        isStable: Bool,
        startedAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.isStable = isStable
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }
}

public enum PermissionState: String, Sendable {
    case authorized
    case notDetermined
    case denied
    case restricted
    case unsupported

    public var displayName: String {
        switch self {
        case .authorized: return "已授权"
        case .notDetermined: return "未请求"
        case .denied: return "已拒绝"
        case .restricted: return "受限制"
        case .unsupported: return "不支持"
        }
    }

    public var isAuthorized: Bool {
        self == .authorized
    }
}

public enum AssetAvailability: String, Sendable {
    case installed
    case supported
    case unsupported
    case unknown

    public var displayName: String {
        switch self {
        case .installed: return "已安装"
        case .supported: return "可安装"
        case .unsupported: return "不支持"
        case .unknown: return "未知"
        }
    }
}

public struct TranslationPair: Hashable, Sendable {
    public let source: SupportedLanguage
    public let target: SupportedLanguage

    public init(source: SupportedLanguage, target: SupportedLanguage) {
        self.source = source
        self.target = target
    }
}

public struct TranslationPreparationRequest: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let pair: TranslationPair

    public init(id: UUID = UUID(), pair: TranslationPair) {
        self.id = id
        self.pair = pair
    }
}

public struct OfflineReadinessReport: Sendable {
    public let microphonePermission: PermissionState
    public let speechPermission: PermissionState
    public let screenCapturePermission: PermissionState
    public let onDeviceRecognition: [SupportedLanguage: Bool]
    public let translationAvailability: [TranslationPair: AssetAvailability]
    public let blockingReasons: [String]
    public let checkedAt: Date

    public init(
        microphonePermission: PermissionState,
        speechPermission: PermissionState,
        screenCapturePermission: PermissionState,
        onDeviceRecognition: [SupportedLanguage: Bool],
        translationAvailability: [TranslationPair: AssetAvailability],
        blockingReasons: [String],
        checkedAt: Date = .now
    ) {
        self.microphonePermission = microphonePermission
        self.speechPermission = speechPermission
        self.screenCapturePermission = screenCapturePermission
        self.onDeviceRecognition = onDeviceRecognition
        self.translationAvailability = translationAvailability
        self.blockingReasons = blockingReasons
        self.checkedAt = checkedAt
    }

    public var isReady: Bool {
        blockingReasons.isEmpty
    }
}

public struct RecognitionHypothesis: Sendable {
    public let language: SupportedLanguage
    public let text: String
    public let confidence: Double
    public let isFinal: Bool
    public let receivedAt: Date
    public let averageSegmentConfidence: Double

    public init(
        language: SupportedLanguage,
        text: String,
        confidence: Double,
        isFinal: Bool,
        receivedAt: Date = .now,
        averageSegmentConfidence: Double
    ) {
        self.language = language
        self.text = text
        self.confidence = confidence
        self.isFinal = isFinal
        self.receivedAt = receivedAt
        self.averageSegmentConfidence = averageSegmentConfidence
    }
}

public struct SpeechPipelineUpdate: Sendable {
    public let sourceLanguage: SupportedLanguage
    public let text: String
    public let confidence: Double
    public let isStable: Bool
    public let receivedAt: Date

    public init(
        sourceLanguage: SupportedLanguage,
        text: String,
        confidence: Double,
        isStable: Bool,
        receivedAt: Date
    ) {
        self.sourceLanguage = sourceLanguage
        self.text = text
        self.confidence = confidence
        self.isStable = isStable
        self.receivedAt = receivedAt
    }
}

public struct TranslationRequest: Sendable {
    public let sourceLanguage: SupportedLanguage
    public let targetLanguage: SupportedLanguage
    public let sourceText: String
    public let revision: Int

    public init(
        sourceLanguage: SupportedLanguage,
        targetLanguage: SupportedLanguage,
        sourceText: String,
        revision: Int
    ) {
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.sourceText = sourceText
        self.revision = revision
    }
}

public struct TranslationResult: Sendable {
    public let sourceLanguage: SupportedLanguage
    public let targetLanguage: SupportedLanguage
    public let sourceText: String
    public let translatedText: String
    public let revision: Int
    public let completedAt: Date

    public init(
        sourceLanguage: SupportedLanguage,
        targetLanguage: SupportedLanguage,
        sourceText: String,
        translatedText: String,
        revision: Int,
        completedAt: Date
    ) {
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.revision = revision
        self.completedAt = completedAt
    }
}
