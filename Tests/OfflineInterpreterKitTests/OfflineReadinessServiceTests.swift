import AVFoundation
import Testing
@testable import OfflineInterpreterKit

struct OfflineReadinessServiceTests {
    @Test
    func audioApplicationGrantWinsForMicrophonePermission() {
        let permission = OfflineReadinessService.resolveMicrophonePermission(
            audioApplicationPermission: .granted,
            capturePermission: .denied
        )

        #expect(permission == .authorized)
    }

    @Test
    func audioApplicationDenyWinsForMicrophonePermission() {
        let permission = OfflineReadinessService.resolveMicrophonePermission(
            audioApplicationPermission: .denied,
            capturePermission: .authorized
        )

        #expect(permission == .denied)
    }

    @Test
    func captureGrantBackfillsUndeterminedAudioApplicationState() {
        let permission = OfflineReadinessService.resolveMicrophonePermission(
            audioApplicationPermission: .undetermined,
            capturePermission: .authorized
        )

        #expect(permission == .authorized)
    }

    @Test
    func undeterminedStateStaysUndeterminedWithoutAnyGrant() {
        let permission = OfflineReadinessService.resolveMicrophonePermission(
            audioApplicationPermission: .undetermined,
            capturePermission: .notDetermined
        )

        #expect(permission == .notDetermined)
    }
}
