import Foundation
import FoundationModels

/// macOS's on-device language model (Foundation Models framework, macOS 26 and later, Apple Intelligence on).
/// Free and needs no API key; the text never leaves the Mac. The model is small (about 3B parameters),
/// so it suits light cleanup better than heavy rewriting.
public struct AppleIntelligenceCleanupProvider: TextCleanupProvider {
    public let id = CleanupProviderKind.apple.rawValue
    public let displayName = CleanupProviderKind.apple.displayName
    public let defaultModel = CleanupProviderKind.apple.defaultModel

    public init() {}

    /// Whether this Mac can run the model now: macOS 26, eligible hardware, Apple Intelligence on,
    /// and the model downloaded.
    public static var isAvailable: Bool {
        if #available(macOS 26, *) { return SystemLanguageModel.default.isAvailable }
        return false
    }

    /// Why the model can't run, for Settings. nil when it can.
    public static var unavailableReason: String? {
        guard #available(macOS 26, *) else { return "macOS 26 以降が必要です。" }
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.deviceNotEligible): return "この Mac では Apple Intelligence を使えません。"
        case .unavailable(.appleIntelligenceNotEnabled):
            return "システム設定の「Apple Intelligence と Siri」で Apple Intelligence をオンにしてください。"
        case .unavailable(.modelNotReady): return "モデルを準備中です。しばらくしてからお試しください。"
        case .unavailable: return "Apple Intelligence を使えません。"
        }
    }

    /// Loads the model into memory so the request after the recording doesn't wait for it.
    public func prewarm() {
        guard #available(macOS 26, *), Self.isAvailable else { return }
        LanguageModelSession(model: Self.model).prewarm()
    }

    public func complete(system: String, user: String, model _: String) async throws -> CleanupCompletion {
        guard #available(macOS 26, *) else { throw CleanupError.invalidResponse }
        // A fresh session per request, so no earlier utterance leaks into the context.
        let session = LanguageModelSession(model: Self.model, instructions: system)
        do {
            let response = try await session.respond(to: user, options: GenerationOptions(temperature: 0))
            guard !response.content.isEmpty else { throw CleanupError.invalidResponse }
            return CleanupCompletion(text: response.content)
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation, .refusal: throw CleanupError.refused
            default: throw CleanupError.invalidResponse
            }
        }
    }

    /// Cleanup only rewrites what the user said, so the guardrails meant for transforming
    /// user-provided text apply.
    @available(macOS 26, *)
    private static var model: SystemLanguageModel {
        SystemLanguageModel(guardrails: .permissiveContentTransformations)
    }
}
