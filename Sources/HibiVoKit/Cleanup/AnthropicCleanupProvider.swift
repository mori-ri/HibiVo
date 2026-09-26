import Foundation

/// Claude via the Messages API (POST /v1/messages). There is no official Swift SDK, so raw HTTP.
public struct AnthropicCleanupProvider: TextCleanupProvider {
    public let id = "anthropic"
    public let displayName = "Anthropic (Claude)"
    public let defaultModel = "claude-opus-5"

    private let urlSession: URLSession
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    public init(urlSession: URLSession = .shared) {
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
        /// Server-side fallback when a safety classifier declines (Opus 5 / Fable 5.1).
        var fallbacks: String?

        enum CodingKeys: String, CodingKey {
            case model, maxTokens = "max_tokens", system, messages, outputConfig = "output_config", fallbacks
        }
    }

    struct Response: Decodable {
        struct Block: Decodable {
            var type: String
            var text: String?
        }
        var content: [Block]
        var stopReason: String?

        enum CodingKeys: String, CodingKey { case content, stopReason = "stop_reason" }
    }

    static func makeRequest(system: String, user: String, model: String) -> Request {
        let supportsEffort = !model.hasPrefix("claude-haiku")
        let supportsFallbacks = model.hasPrefix("claude-opus-5") || model.hasPrefix("claude-fable-5")
        return Request(
            model: model,
            system: system,
            messages: [.init(content: user)],
            outputConfig: supportsEffort ? .init(effort: "low") : nil,
            fallbacks: supportsFallbacks ? "default" : nil)
    }

    public func complete(system: String, user: String, model: String, apiKey: String) async throws -> String {
        let body = Self.makeRequest(system: system, user: user, model: model)
        var headers = ["x-api-key": apiKey, "anthropic-version": "2023-06-01"]
        if body.fallbacks != nil { headers["anthropic-beta"] = "server-side-fallback-2026-07-01" }
        let request = try HTTPJSON.post(endpoint, headers: headers, body: body, timeout: 15)
        let (data, response) = try await urlSession.data(for: request)
        try HTTPJSON.checkStatus(response)
        return try Self.parse(data)
    }

    static func parse(_ data: Data) throws -> String {
        let response = try JSONDecoder().decode(Response.self, from: data)
        if response.stopReason == "refusal" { throw CleanupError.refused }
        let text = response.content.filter { $0.type == "text" }.compactMap(\.text).joined()
        guard !text.isEmpty else { throw CleanupError.invalidResponse }
        return text
    }
}
