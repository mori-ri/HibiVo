import Foundation

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

    public init(text: String, usage: TokenUsage? = nil) {
        self.text = text
        self.usage = usage
    }
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
    /// - Parameter timeout: Kept above CleanupCoordinator's longest deadline, which is what actually bounds a request.
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

    static func checkStatus(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw CleanupError.invalidResponse }
        switch http.statusCode {
        case 200..<300: return
        case 401, 403: throw CleanupError.unauthorized
        default: throw CleanupError.http(http.statusCode)
        }
    }
}
