import Foundation
import OSLog

public enum CleanupError: Error, Equatable, Sendable {
    case missingAPIKey
    case missingModel
    case unauthorized
    case http(Int)
    case refused
    case invalidResponse
    case rejectedByGuard
    case timedOut
}

/// An LLM that rewrites text. It only knows how to send one system + user message and return text.
/// Each provider is created with its own credentials, since they differ by provider
/// (a single API key, or an AWS access key pair).
public protocol TextCleanupProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    var defaultModel: String { get }

    func complete(system: String, user: String, model: String) async throws -> CleanupCompletion
}

/// Billable tokens reported by the provider for one request.
public struct TokenUsage: Codable, Hashable, Sendable {
    public var input: Int
    public var output: Int

    public init(input: Int, output: Int) {
        self.input = input
        self.output = output
    }

    public static let zero = TokenUsage(input: 0, output: 0)

    public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(input: lhs.input + rhs.input, output: lhs.output + rhs.output)
    }
}

/// One cleanup response: the rewritten text and, when the provider reports it, its token usage.
public struct CleanupCompletion: Equatable, Sendable {
    public var text: String
    public var usage: TokenUsage?
    /// True when the model stopped at the output cap, so `text` is cut off.
    public var truncated: Bool

    public init(text: String, usage: TokenUsage? = nil, truncated: Bool = false) {
        self.text = text
        self.usage = usage
        self.truncated = truncated
    }
}

/// How long and how large one request may be. Every provider takes one, so the same provider types serve
/// short cleanups and long meeting minutes.
public struct CleanupLimits: Sendable, Equatable {
    /// Output cap; nil keeps each provider's cleanup default (or sends none where it has none).
    public var maxTokens: Int?
    public var timeout: TimeInterval
    /// Asks for low effort or thinking where the model takes it; otherwise the model's default applies.
    public var lowEffort: Bool

    /// Short rewrites, bounded by CleanupCoordinator's deadline.
    public static let cleanup = CleanupLimits(maxTokens: nil, timeout: 60, lowEffort: true)
    /// Minutes of an hour-long meeting: long input, a few thousand tokens out (plus thinking), and worth the
    /// model's default effort. Requests stay non-streaming, so the cap stays where a single response fits.
    public static let minutes = CleanupLimits(maxTokens: 16_000, timeout: 600, lowEffort: false)
}

/// The cleanup providers users can pick in Settings.
public enum CleanupProviderKind: String, CaseIterable, Identifiable, Sendable {
    case anthropic
    case openAICompatible = "openai-compatible"
    case bedrock
    case gemini

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .anthropic: "Anthropic (Claude)"
        case .openAICompatible: "OpenAI 互換"
        case .bedrock: "Amazon Bedrock"
        case .gemini: "Google Gemini"
        }
    }

    public var defaultModel: String {
        switch self {
        case .anthropic: "claude-haiku-4-5"
        case .openAICompatible: ""
        case .bedrock: "global.anthropic.claude-haiku-4-5-20251001-v1:0"
        case .gemini: "gemini-3.5-flash-lite"
        }
    }
}

/// Keychain account names for cleanup credentials.
public enum SecretAccount {
    public static let anthropic = "anthropic"
    public static let openAICompatible = "openai-compatible"
    public static let bedrockAPIKey = "bedrock-api-key"  // Bedrock API key (bearer token)
    public static let awsAccessKeyID = "aws-access-key-id"
    public static let awsSecretAccessKey = "aws-secret-access-key"
    public static let awsSessionToken = "aws-session-token"
    /// Same account as the Gemini transcription provider's ID, so one key serves both.
    public static let gemini = "gemini"
}

enum HTTPJSON {
    /// - Parameter timeout: Kept at least as long as CleanupCoordinator's longest deadline, which is what actually
    ///   bounds a request.
    static func post(_ url: URL, headers: [String: String], body: some Encodable, timeout: TimeInterval) throws
        -> URLRequest
    {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private static let log = Logger(subsystem: "io.github.mori-ri.hibivo", category: "cleanup")

    /// - Parameter data: The response body. On failure, the provider's error message is logged, since the status
    ///   code alone rarely says what to fix (e.g. a Bedrock model that needs an inference profile).
    static func checkStatus(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw CleanupError.invalidResponse }
        if !(200..<300).contains(http.statusCode), let message = errorMessage(data) {
            log.error("Cleanup HTTP \(http.statusCode, privacy: .public): \(message, privacy: .public)")
        }
        switch http.statusCode {
        case 200..<300: return
        case 401, 403: throw CleanupError.unauthorized
        default: throw CleanupError.http(http.statusCode)
        }
    }

    /// The `message` of an error body: top-level (Bedrock) or under `error` (Anthropic, OpenAI, Gemini).
    /// Error messages describe the request, not its content, so they are safe to log.
    static func errorMessage(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let message =
            (json["message"] as? String) ?? ((json["error"] as? [String: Any])?["message"] as? String)
        return message.map { String($0.prefix(300)) }
    }
}
