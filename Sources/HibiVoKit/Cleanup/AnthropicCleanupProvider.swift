import Foundation

/// Claude via the Messages API (POST /v1/messages). There is no official Swift SDK, so raw HTTP.
public struct AnthropicCleanupProvider: TextCleanupProvider {
    public let id = "anthropic"
    public let displayName = "Anthropic (Claude)"
    public let defaultModel = CleanupProviderKind.anthropic.defaultModel

    private let apiKey: String
    private let urlSession: URLSession
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    public init(apiKey: String, urlSession: URLSession = .shared) {
        self.apiKey = apiKey
        self.urlSession = urlSession
    }

    struct Request: Encodable {
        struct Message: Encodable {
            var role = "user"
            var content: String
        }
        struct OutputConfig: Encodable {
            var effort: String
        }

        var model: String
        var maxTokens = 4_000
        var system: String
        var messages: [Message]
        /// Cleanup is a light rewrite; low effort keeps latency down on models that think adaptively.
        var outputConfig: OutputConfig?
        /// Server-side fallback when a safety classifier declines (Opus 5 and later, Fable 5,
        /// Sonnet 5.5). Not sent on Bedrock, which doesn't take it.
        var fallbacks: String?

        enum CodingKeys: String, CodingKey {
            case model
            case maxTokens = "max_tokens"
            case system, messages
            case outputConfig = "output_config"
            case fallbacks
        }
    }

    struct Response: Decodable {
        struct Block: Decodable {
            var type: String
            var text: String?
        }
        struct Usage: Decodable {
            var inputTokens: Int
            var outputTokens: Int
            var cacheCreationInputTokens: Int?
            var cacheReadInputTokens: Int?

            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
                case cacheCreationInputTokens = "cache_creation_input_tokens"
                case cacheReadInputTokens = "cache_read_input_tokens"
            }

            var tokens: TokenUsage {
                TokenUsage(
                    input: inputTokens + (cacheCreationInputTokens ?? 0) + (cacheReadInputTokens ?? 0),
                    output: outputTokens)
            }
        }
        var content: [Block]
        var stopReason: String?
        var usage: Usage?

        enum CodingKeys: String, CodingKey {
            case content
            case stopReason = "stop_reason"
            case usage
        }
    }

    /// Shared with Bedrock, whose model IDs look like `anthropic.claude-…` or `global.anthropic.claude-…`.
    static func makeRequest(system: String, user: String, model: String, allowFallbacks: Bool = true) -> Request {
        let name = model.range(of: "anthropic.").map { String(model[$0.upperBound...]) } ?? model
        // Haiku 4.5 rejects effort; Haiku 5.5 takes it (and defaults to medium, so low is worth sending).
        let supportsEffort = !name.hasPrefix("claude-haiku-4")
        let supportsFallbacks =
            allowFallbacks
            && ["claude-opus-5", "claude-fable-5", "claude-sonnet-5-5"].contains { name.hasPrefix($0) }
        return Request(
            model: model,
            system: system,
            messages: [.init(content: user)],
            outputConfig: supportsEffort ? .init(effort: "low") : nil,
            fallbacks: supportsFallbacks ? "default" : nil)
    }

    public func complete(system: String, user: String, model: String) async throws -> CleanupCompletion {
        let body = Self.makeRequest(system: system, user: user, model: model)
        var headers = ["x-api-key": apiKey, "anthropic-version": "2023-06-01"]
        if body.fallbacks != nil { headers["anthropic-beta"] = "server-side-fallback-2026-07-01" }
        let request = try HTTPJSON.post(endpoint, headers: headers, body: body, timeout: 60)
        let (data, response) = try await urlSession.data(for: request)
        try HTTPJSON.checkStatus(response)
        return try Self.parse(data)
    }

    static func parse(_ data: Data) throws -> CleanupCompletion {
        let response = try JSONDecoder().decode(Response.self, from: data)
        if response.stopReason == "refusal" { throw CleanupError.refused }
        let text = response.content.filter { $0.type == "text" }.compactMap(\.text).joined()
        guard !text.isEmpty else { throw CleanupError.invalidResponse }
        return CleanupCompletion(text: text, usage: response.usage?.tokens)
    }
}
