import Foundation
import OSLog

public struct CleanupOutcome: Equatable, Sendable {
    /// What should be pasted: the cleaned text, or the raw transcript as a fallback.
    public var text: String
    public var didCleanup: Bool
    /// Set when cleanup was attempted and failed; the raw transcript is used instead.
    public var failure: CleanupError?
    /// Tokens billed for the request, even when its output was rejected. nil when no request was made
    /// or the provider did not report usage.
    public var usage: TokenUsage?
}

/// Runs one cleanup with a hard timeout and falls back to the raw transcript on any problem.
/// Cleanup must never cost the user their utterance.
public struct CleanupCoordinator: Sendable {
    public struct Request: Sendable {
        public var raw: String
        public var mode: CleanupMode
        public var vocabulary: [CleanupPromptBuilder.Term]
        public var appName: String?
        /// Used only by `.custom`.
        public var customInstructions: String = ""
    }

    public var timeout: Duration
    private let log = Logger(subsystem: "io.github.mori-ri.hibivo", category: "cleanup")

    public init(timeout: Duration = .seconds(5)) {
        self.timeout = timeout
    }

    /// - Parameter provider: nil when the selected provider has no credentials configured.
    public func run(_ request: Request, provider: (any TextCleanupProvider)?, model: String) async -> CleanupOutcome {
        let raw = request.raw
        guard request.mode != .raw else { return CleanupOutcome(text: raw, didCleanup: false, failure: nil) }
        guard let provider else { return fallback(raw, .missingAPIKey) }
        guard !model.isEmpty else { return fallback(raw, .missingModel) }

        let system = CleanupPromptBuilder.systemPrompt(
            mode: request.mode, customInstructions: request.customInstructions, vocabulary: request.vocabulary,
            appName: request.appName)
        let user = CleanupPromptBuilder.userMessage(transcript: raw)

        do {
            let output = try await withTimeout(timeout) {
                try await provider.complete(system: system, user: user, model: model)
            }
            guard let text = CleanupOutputGuard.validate(output.text, raw: raw, mode: request.mode) else {
                return fallback(raw, .rejectedByGuard, usage: output.usage)
            }
            return CleanupOutcome(text: text, didCleanup: true, failure: nil, usage: output.usage)
        } catch let error as CleanupError {
            return fallback(raw, error)
        } catch {
            log.error("Cleanup failed: \(error.localizedDescription, privacy: .public)")
            return fallback(raw, (error as? URLError)?.code == .timedOut ? .timedOut : .invalidResponse)
        }
    }

    /// What dictation does with a finished transcript: apply the dictionary, clean up, then drop
    /// the period after a lone word.
    /// Shared with the eval runner so it measures exactly this path.
    /// - Returns: The transcript after dictionary replacement, and the cleanup outcome.
    public func run(
        transcript: String, vocabulary: [VocabularyEntry], mode: CleanupMode, appName: String?,
        customInstructions: String, provider: (any TextCleanupProvider)?, model: String
    ) async -> (raw: String, outcome: CleanupOutcome) {
        let raw = VocabularyReplacer.apply(vocabulary, to: transcript)
        var outcome = await run(
            Request(
                raw: raw, mode: mode, vocabulary: vocabulary.map(\.promptTerm), appName: appName,
                customInstructions: customInstructions),
            provider: provider, model: model)
        outcome.text = TrailingPeriod.trimmed(outcome.text)
        return (raw, outcome)
    }

    private func fallback(_ raw: String, _ error: CleanupError, usage: TokenUsage? = nil) -> CleanupOutcome {
        log.notice("Cleanup fell back to raw transcript: \(String(describing: error), privacy: .public)")
        return CleanupOutcome(text: raw, didCleanup: false, failure: error, usage: usage)
    }
}

/// Races `operation` against a deadline; the loser is cancelled.
func withTimeout<T: Sendable>(
    _ timeout: Duration, operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw CleanupError.timedOut
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw CleanupError.timedOut }
        return result
    }
}
