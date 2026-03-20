import AVFoundation
import CoreGraphics
import AppKit
import Foundation
import Speech
import Translation

public final class OfflineReadinessService: @unchecked Sendable {
    public init() {}

    public func requestMissingPermissions(for audioSource: AudioSourceKind) async {
        if audioSource == .microphone && AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }

        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            _ = await requestSpeechAuthorization()
        }

        if audioSource == .systemAudio && !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }
    }

    public func checkReadiness(
        for audioSource: AudioSourceKind,
        sourceLanguage: SupportedLanguage,
        targetLanguage: SupportedLanguage
    ) async -> OfflineReadinessReport {
        let microphonePermission = Self.mapMicrophonePermission(AVCaptureDevice.authorizationStatus(for: .audio))
        let speechPermission = await currentSpeechPermission()
        let screenCapturePermission = CGPreflightScreenCaptureAccess() ? PermissionState.authorized : .denied

        var onDeviceRecognition: [SupportedLanguage: Bool] = [:]
        for language in SupportedLanguage.allCases {
            let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language.localeIdentifier))
            onDeviceRecognition[language] = recognizer?.supportsOnDeviceRecognition == true
        }

        let availability = LanguageAvailability()
        var translationAvailability: [TranslationPair: AssetAvailability] = [:]
        for source in SupportedLanguage.allCases {
            for target in SupportedLanguage.allCases where source != target {
                let status = await availability.status(from: source.localeLanguage, to: target.localeLanguage)
                translationAvailability[TranslationPair(source: source, target: target)] = mapTranslationStatus(status)
            }
        }

        var blockingReasons: [String] = []
        if speechPermission != .authorized {
            blockingReasons.append("语音识别权限未授权。")
        }

        switch audioSource {
        case .microphone:
            if microphonePermission != .authorized {
                blockingReasons.append("麦克风权限未授权。")
            }
        case .systemAudio:
            break
        }

        let pair = TranslationPair(source: sourceLanguage, target: targetLanguage)
        let status = translationAvailability[pair] ?? .unknown
        if status == .unsupported {
            blockingReasons.append("\(sourceLanguage.displayName) 到 \(targetLanguage.displayName) 的离线翻译不受支持。")
        }

        return OfflineReadinessReport(
            microphonePermission: microphonePermission,
            speechPermission: speechPermission,
            screenCapturePermission: screenCapturePermission,
            onDeviceRecognition: onDeviceRecognition,
            translationAvailability: translationAvailability,
            blockingReasons: blockingReasons
        )
    }

    public func openPrivacySettings(for audioSource: AudioSourceKind) {
        let rawURL: String
        switch audioSource {
        case .microphone:
            rawURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .systemAudio:
            rawURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        }

        if let url = URL(string: rawURL) {
            NSWorkspace.shared.open(url)
        }
    }

    public func openSpeechSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition") {
            NSWorkspace.shared.open(url)
        }
    }

    private func currentSpeechPermission() async -> PermissionState {
        Self.mapSpeechPermission(SFSpeechRecognizer.authorizationStatus())
    }

    private func requestSpeechAuthorization() async -> PermissionState {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: Self.mapSpeechPermission(status))
            }
        }
    }

    private static func mapMicrophonePermission(_ status: AVAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .unsupported
        }
    }

    private static func mapSpeechPermission(_ status: SFSpeechRecognizerAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .unsupported
        }
    }

    private func mapTranslationStatus(_ status: LanguageAvailability.Status) -> AssetAvailability {
        switch status {
        case .installed: return .installed
        case .supported: return .supported
        case .unsupported: return .unsupported
        @unknown default: return .unknown
        }
    }
}
