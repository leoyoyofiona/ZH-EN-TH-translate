import Foundation
@preconcurrency import Translation

@MainActor
public final class TranslationPipeline {
    private let lexiconOverlay: LexiconOverlay
    private var sessionCache: [TranslationPair: TranslationSession] = [:]
    private var resultCache: [CacheKey: String] = [:]
    private var cacheOrder: [CacheKey] = []
    private let maxCacheEntries = 96

    public init(lexiconOverlay: LexiconOverlay) {
        self.lexiconOverlay = lexiconOverlay
    }

    public func prepare(source: SupportedLanguage, target: SupportedLanguage) async {
        guard source != target else { return }
        let pair = TranslationPair(source: source, target: target)
        do {
            _ = try await session(for: pair)
        } catch {
            // Warm-up failure should not block later retries.
        }
    }

    public func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        if request.sourceLanguage == request.targetLanguage {
            return TranslationResult(
                sourceLanguage: request.sourceLanguage,
                targetLanguage: request.targetLanguage,
                sourceText: request.sourceText,
                translatedText: request.sourceText,
                revision: request.revision,
                completedAt: .now
            )
        }

        let pair = TranslationPair(source: request.sourceLanguage, target: request.targetLanguage)
        let cacheKey = CacheKey(pair: pair, sourceText: request.sourceText)
        if let cached = resultCache[cacheKey] {
            return TranslationResult(
                sourceLanguage: request.sourceLanguage,
                targetLanguage: request.targetLanguage,
                sourceText: request.sourceText,
                translatedText: cached,
                revision: request.revision,
                completedAt: .now
            )
        }

        let session = try await session(for: pair)
        let response = try await session.translate(request.sourceText)
        let protectedText = lexiconOverlay.protectTerms(in: response.targetText, sourceText: request.sourceText)
        storeCachedTranslation(protectedText, for: cacheKey)

        return TranslationResult(
            sourceLanguage: request.sourceLanguage,
            targetLanguage: request.targetLanguage,
            sourceText: request.sourceText,
            translatedText: protectedText,
            revision: request.revision,
            completedAt: .now
        )
    }

    private func session(for pair: TranslationPair) async throws -> TranslationSession {
        if let cached = sessionCache[pair] {
            return cached
        }

        let session = TranslationSession(installedSource: pair.source.localeLanguage, target: pair.target.localeLanguage)
        try await session.prepareTranslation()
        sessionCache[pair] = session
        return session
    }

    private func storeCachedTranslation(_ text: String, for key: CacheKey) {
        resultCache[key] = text
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)

        if cacheOrder.count > maxCacheEntries, let oldest = cacheOrder.first {
            cacheOrder.removeFirst()
            resultCache.removeValue(forKey: oldest)
        }
    }
}

private struct CacheKey: Hashable {
    let pair: TranslationPair
    let sourceText: String
}
