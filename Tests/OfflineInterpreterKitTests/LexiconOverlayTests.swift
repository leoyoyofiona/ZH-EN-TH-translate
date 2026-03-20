import Testing
@testable import OfflineInterpreterKit

struct LexiconOverlayTests {
    @Test
    func protectTermsNormalizesKnownBrand() {
        let overlay = LexiconOverlay()

        let output = overlay.protectTerms(in: "แอปเปิล เปิดตัว iPhone รุ่นใหม่", sourceText: "Apple 发布了新 iPhone")

        #expect(output.contains("Apple"))
        #expect(output.contains("iPhone"))
    }

    @Test
    func contextualStringsExposeKnownTerms() {
        let overlay = LexiconOverlay()

        let thaiTerms = overlay.contextualStrings(for: .th)

        #expect(thaiTerms.contains("แอปเปิล"))
        #expect(thaiTerms.contains("ไอโฟน"))
    }
}
