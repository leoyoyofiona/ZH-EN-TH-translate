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
        let translatedText = try await translateText(
            request.sourceText,
            with: session,
            pair: pair,
            timeout: timeout(for: request.sourceText),
            allowRetry: true
        )
        let protectedText = lexiconOverlay.protectTerms(in: translatedText, sourceText: request.sourceText)
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

    private func translateText(
        _ sourceText: String,
        with translatorSession: TranslationSession,
        pair: TranslationPair,
        timeout: Duration,
        allowRetry: Bool
    ) async throws -> String {
        do {
            return try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    let response = try await translatorSession.translate(sourceText)
                    return response.targetText
                }

                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw TranslationTimeoutError()
                }

                let translatedText = try await group.next() ?? ""
                group.cancelAll()
                return translatedText
            }
        } catch is TranslationTimeoutError where allowRetry {
            sessionCache.removeValue(forKey: pair)
            let freshSession = try await session(for: pair)
            return try await translateText(
                sourceText,
                with: freshSession,
                pair: pair,
                timeout: .seconds(4),
                allowRetry: false
            )
        }
    }

    private func timeout(for sourceText: String) -> Duration {
        switch sourceText.count {
        case ..<40:
            return .seconds(1.6)
        case ..<120:
            return .seconds(2.2)
        default:
            return .seconds(3)
        }
    }
}

private struct CacheKey: Hashable {
    let pair: TranslationPair
    let sourceText: String
}

private struct TranslationTimeoutError: Error {}
