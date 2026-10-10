import Foundation

/// Any `/chat/completions` endpoint: OpenAI, Groq, OpenRouter, an in-house gateway, etc.
public struct OpenAICompatibleCleanupProvider: TextCleanupProvider {
    public let id = "openai-compatible"
    public let displayName = "OpenAI 互換"
    public let defaultModel = ""

    private let baseURL: URL
    private let apiKey: String
    let limits: CleanupLimits
    private let urlSession: URLSession

    public static let defaultBaseURL = "https://api.openai.com/v1"

    /// - Parameter limits: Only the timeout applies. No output cap is sent, because endpoints disagree on
    ///   its name (`max_tokens` or `max_completion_tokens`) and reject the one they don't know.
    public init(baseURL: URL, apiKey: String, limits: CleanupLimits = .cleanup, urlSession: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.limits = limits
        self.urlSession = urlSession
    }

    struct Request: Encodable {
        struct Message: Encodable {
            var role: String
            var content: String
        }
        var model: String
        var messages: [Message]
        var temperature: Double = 0
    }

    struct Response: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { var content: String? }
            var message: Message
            var finishReason: String?

            enum CodingKeys: String, CodingKey {
                case message
                case finishReason = "finish_reason"
            }
        }
        struct Usage: Decodable {
            var promptTokens: Int
            var completionTokens: Int

            enum CodingKeys: String, CodingKey {
                case promptTokens = "prompt_tokens"
                case completionTokens = "completion_tokens"
            }
        }
        var choices: [Choice]
        var usage: Usage?
    }

    public func complete(system: String, user: String, model: String) async throws -> CleanupCompletion {
        let body = Request(
            model: model,
            messages: [.init(role: "system", content: system), .init(role: "user", content: user)])
        let request = try HTTPJSON.post(
            baseURL.appending(path: "chat/completions"),
            headers: ["Authorization": "Bearer \(apiKey)"], body: body, timeout: limits.timeout)
        let (data, response) = try await urlSession.data(for: request)
        try HTTPJSON.checkStatus(response, data: data)
        return try Self.parse(data)
    }

    static func parse(_ data: Data) throws -> CleanupCompletion {
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard let text = response.choices.first?.message.content, !text.isEmpty else {
            throw CleanupError.invalidResponse
        }
        return CleanupCompletion(
            text: text, usage: response.usage.map { TokenUsage(input: $0.promptTokens, output: $0.completionTokens) },
            truncated: response.choices.first?.finishReason == "length")
    }
}
