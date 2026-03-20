import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

public protocol AudioCaptureController: AnyObject, Sendable {
    var onPCMBuffer: ((AVAudioPCMBuffer) -> Void)? { get set }
    var onSampleBuffer: ((CMSampleBuffer) -> Void)? { get set }
    func start() async throws
    func stop() async
}

public final class MicrophoneAudioCapture: AudioCaptureController, @unchecked Sendable {
    public var onPCMBuffer: ((AVAudioPCMBuffer) -> Void)?
    public var onSampleBuffer: ((CMSampleBuffer) -> Void)?

    private let engine = AVAudioEngine()
    private var isRunning = false

    public init() {}

    public func start() async throws {
        guard !isRunning else { return }
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 512, format: format) { [weak self] buffer, _ in
            self?.onPCMBuffer?(buffer)
        }

        engine.prepare()
        try engine.start()
        isRunning = true
    }

    public func stop() async {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }
}

public final class SystemAudioCapture: NSObject, AudioCaptureController, @unchecked Sendable {
    public var onPCMBuffer: ((AVAudioPCMBuffer) -> Void)?
    public var onSampleBuffer: ((CMSampleBuffer) -> Void)?

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "OfflineInterpreter.SystemAudioCapture")

    public func start() async throws {
        guard stream == nil else { return }

        do {
            let shareableContent = try await SCShareableContent.current
            guard let display = shareableContent.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? shareableContent.displays.first else {
                throw NSError(domain: "OfflineInterpreter.SystemAudioCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "未找到可共享显示器，无法采集系统音频。"])
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            configuration.capturesAudio = true
            configuration.captureMicrophone = false
            configuration.sampleRate = 16_000
            configuration.channelCount = 1
            configuration.excludesCurrentProcessAudio = true

            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try await stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            try await stream.startCapture()
            self.stream = stream
        } catch {
            throw mapCaptureError(error)
        }
    }

    public func stop() async {
        guard let stream else { return }
        do {
            try await stream.stopCapture()
        } catch {
            // Ignore shutdown failures.
        }
        self.stream = nil
    }
}

extension SystemAudioCapture: SCStreamOutput, SCStreamDelegate {
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        onSampleBuffer?(sampleBuffer)
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("System audio capture stopped: \(error.localizedDescription)")
    }
}

private extension SystemAudioCapture {
    func mapCaptureError(_ error: Error) -> Error {
        let nsError = error as NSError
        let preflightAccess = CGPreflightScreenCaptureAccess()
        NSLog(
            "System audio capture failed. preflight=%d domain=%@ code=%ld description=%@",
            preflightAccess,
            nsError.domain,
            nsError.code,
            nsError.localizedDescription
        )

        if looksLikePermissionFailure(nsError) {
            return NSError(
                domain: "OfflineInterpreter.SystemAudioCapture",
                code: nsError.code,
                userInfo: [
                    NSLocalizedDescriptionKey: "系统音频采集被 macOS 拒绝。底层返回：\(nsError.localizedDescription) [\(nsError.domain):\(nsError.code)]，预检查权限=\(preflightAccess ? "已授权" : "未授权")。如果你刚刚在系统设置里打开权限，请先完全退出应用后再重开一次。"
                ]
            )
        }

        return NSError(
            domain: "OfflineInterpreter.SystemAudioCapture",
            code: nsError.code,
            userInfo: [
                NSLocalizedDescriptionKey: "系统音频启动失败：\(nsError.localizedDescription) [\(nsError.domain):\(nsError.code)]"
            ]
        )
    }

    func looksLikePermissionFailure(_ error: NSError) -> Bool {
        let lowered = [
            error.domain,
            error.localizedDescription,
            error.localizedFailureReason ?? "",
            error.localizedRecoverySuggestion ?? ""
        ]
        .joined(separator: " ")
        .lowercased()

        if lowered.contains("not authorized")
            || lowered.contains("permission")
            || lowered.contains("denied")
            || lowered.contains("privacy")
            || lowered.contains("unauthorized") {
            return true
        }

        return false
    }
}
